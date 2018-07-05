#!/bin/bash

#根据java pid抓取jstat信息

#本脚本需要bc支持，请先安装

#问题1：java进程会重启，这个监控应该跟随重启做变化
#判断逻辑，（每秒一次）取5次FGC值不一样的数据，用临近的两次数据进行比较，GCT_new-GCT_old/5>阈值，且O_new-O_old<阈值，且连续五次发生，判定为OOM
#为了降低复杂度，与restart.sh脚本配套使用，同时起，同时关；同时也可以单独启动

#jstat样例
#各字段说明参考 https://blog.csdn.net/maosijunzi/article/details/46049117
#root@iZ2zefnwiq237sir84drinZ:/opt/hwzsh# jstat -gc -t 740 1000 5
#Timestamp        S0C    S1C    S0U    S1U      EC       EU        OC         OU       MC     MU    CCSC   CCSU   YGC     YGCT    FGC    FGCT     GCT   
#         1241.0 145920.0 150016.0  0.0   33553.6 2209280.0 214669.1  695808.0   246437.2  116056.0 113910.8 11136.0 10740.2     21    1.453   4      1.746    3.199
#         1242.1 145920.0 150016.0  0.0   33553.6 2209280.0 214669.1  695808.0   246437.2  116056.0 113910.8 11136.0 10740.2     21    1.453   4      1.746    3.199


#常量
#关键字，用于唯一定位java进程
KEYWORD='qypms-boot.jar'
SHDIR='/opt/hwzsh'
LOGFILE='/opt/hwzsh/jvmcheck.log'
RESTARTSCRIPT='/home/work/app/pms/restart.sh'

#阈值，为了避免浮点数出现问题，下面两个变量的单位是%,后续的计算均采用*100的方式进行，取值范围为0-100
#targetgctimepercent定义fullgc耗时占总时长的比例
targetgctimepercent=90
#targetheappercent定义fullgc后old-heap回收的比例
targetheappercent=10

#定义日志格式化内容
loggerError(){
	echo `date "+%Y-%m-%d %H:%M:%S"`" [ERROR]"
}

loggerInfo(){
	echo `date "+%Y-%m-%d %H:%M:%S"`" [INFO]"
}

loggerDebug(){
	echo `date "+%Y-%m-%d %H:%M:%S"`" [DEBUG]"
}

#用于获取当前关键字对应的进程pid
getCurrentPid(){
	pidcount=`ps -ef|grep java|grep $1|grep -v grep|awk '{print $2}'|wc -l`
	if [[ ${pidcount} -eq 0 ]]; then
		#当无进程匹配时
		echo "`loggerError` 关键字"${KEYWORD}"匹配数为"${pidcount}"，请检查服务是否正确启动！">> ${LOGFILE}
		exit 1
	elif [[ ${pidcount} -ge 2 ]]; then
		#当有多个进程匹配时
		echo "`loggerError` 关键字"${KEYWORD}"匹配数为"${pidcount}"，请检查服务是否正确启动！">> ${LOGFILE}
		exit 1
	fi
	pid=`ps -ef|grep java|grep $1|grep -v grep|awk '{print $2}'`
	echo ${pid}
}

getJstatInfo(){
	jstatinfo=`jstat -gc -t $1 1 1|tail -1`
	#返回jstat行信息
	echo ${jstatinfo}
}

#两个入参 javapid,gccount
getNextDiffJstatInfo(){
	currentjstatinfo=`jstat -gc -t $1 1 1|tail -1`
	currentgccount=`echo ${currentjstatinfo}|awk '{print $16}'`
	currentoldgen=`echo ${currentjstatinfo}|awk '{print $9}'`
	#将收集到的currentgccount与入参的进行比较，获取currentgccount比入参大的那一行信息
	while [[ ${currentgccount} -eq $2 ]]; do
		#statements
		sleep 3
		currentjstatinfo=`jstat -gc -t $1 1 1|tail -1`
		currentgccount=`echo ${currentjstatinfo}|awk '{print $16}'`
		currentoldgen=`echo ${currentjstatinfo}|awk '{print $9}'`
	done
	#返回jstat行信息拼接currentoldgen
	echo ${currentjstatinfo}';'${currentoldgen}
}




################# main ##################
#获取pid
currentpid=`getCurrentPid ${KEYWORD}`
if [[ $? != 0 ]]; then
	#无法正确获得pid
	echo "无法获取关键字 "${KEYWORD}" 的pid，程序退出！"
	exit 1
fi

echo "`loggerInfo` 开始监控pid:"${currentpid}>> ${LOGFILE}


#初始化
matchcount=1

until [[ ${matchcount} -eq 5 ]]; do
	sleep 1
	#获取jstat信息
	jstatinfo_1=`getJstatInfo ${currentpid}`
	#老年代全部大小,该变量通用
	oldgensize=`echo ${jstatinfo_1}|awk '{print $8}'`
	echo "`loggerDebug` oldgensize:"${oldgensize}>> ${LOGFILE}
	#取时间戳
	gcstamp_1=`echo ${jstatinfo_1}|awk '{print $1}'`
	#取FGC值
	gccount_1=`echo ${jstatinfo_1}|awk '{print $16}'`
	#取GCT值
	gctime_1=`echo ${jstatinfo_1}|awk '{print $17}'`
	oldgen_1_end=`echo ${jstatinfo_1}|awk '{print $9}'`

	jstatinfo_2=`getNextDiffJstatInfo ${currentpid} ${gccount_1}`
	#oldgen_1_end=`echo ${jstatinfo_2}|awk -F\; '{print $2}'`
	gcstamp_2=`echo ${jstatinfo_2}|awk -F\; '{print $1}'|awk '{print $1}'`
	oldgen_2_start=`echo ${jstatinfo_2}|awk -F\; '{print $1}'|awk '{print $9}'`
	gccount_2=`echo ${jstatinfo_2}|awk -F\; '{print $1}'|awk '{print $16}'`
	gctime_2=`echo ${jstatinfo_2}|awk -F\; '{print $1}'|awk '{print $17}'`

	#计算结果为避免进行浮点数比较大小，统一取整
	gctime_percent=`echo "scale=0;(${gctime_2}-${gctime_1})*100/(${gcstamp_2}-${gcstamp_1})"|bc`
	#这里有一种可能，第二次的start值比第一次的end值还大，相减出现负值
	heap_percent=`echo "scale=0;(${oldgen_1_end}-${oldgen_2_start})*100/${oldgensize}"|bc`
	#调试信息
	echo "`loggerDebug` 比较-2 gccount_2:"${gccount_2}" gccount_1:"${gccount_1}>> ${LOGFILE}
	echo "`loggerDebug` 比较-2 oldgen_1_end:"${oldgen_1_end}" oldgen_2_start:"${oldgen_2_start}>> ${LOGFILE}
	echo "`loggerDebug` 比较-2 gctime_2:"${gctime_2}" gctime_1:"${gctime_1}" gcstamp_2:"${gcstamp_2}" gcstamp_1:"${gcstamp_1}>> ${LOGFILE}
	echo "`loggerDebug` 比较-2 gctime_percent:"${gctime_percent}" heap_percent:"${heap_percent}>> ${LOGFILE}
	#echo ${jstatinfo_2}
	#echo ${oldgen_1_end}
	#echo ${oldgen_2_start}
	#echo ${gctime_percent}
	#echo ${targetgctimepercent}
	#echo ${heap_percent}
	#echo ${targetheappercent}
	#进行比较
	if [ ${gctime_percent} -ge ${targetgctimepercent}  -a  ${heap_percent} -le ${targetheappercent} ]; then
		#条件满足，matchcount+1
		echo "`loggerDebug` 满足-2,进行下一次比较" >> ${LOGFILE}
		matchcount=`expr ${matchcount} + 1`
	else
		#条件不满足，matchcount重置为1
		matchcount=1
		echo "`loggerDebug` 不满足-2,matchcount重置为1" >> ${LOGFILE}
		continue
	fi

	jstatinfo_3=`getNextDiffJstatInfo ${currentpid} ${gccount_2}`
	oldgen_2_end=`echo ${jstatinfo_3}|awk -F\; '{print $2}'`
	gcstamp_3=`echo ${jstatinfo_3}|awk -F\; '{print $1}'|awk '{print $1}'`
	oldgen_3_start=`echo ${jstatinfo_3}|awk -F\; '{print $1}'|awk '{print $9}'`
	gccount_3=`echo ${jstatinfo_3}|awk -F\; '{print $1}'|awk '{print $16}'`
	gctime_3=`echo ${jstatinfo_3}|awk -F\; '{print $1}'|awk '{print $17}'`
	
	#计算结果为避免进行浮点数比较大小，统一取整
	gctime_percent=`echo "scale=0;(${gctime_3}-${gctime_2})*100/(${gcstamp_3}-${gcstamp_2})"|bc`
	heap_percent=`echo "scale=0;(${oldgen_2_end}-${oldgen_3_start})*100/${oldgensize}"|bc`
	echo "`loggerDebug` 比较-3 gccount_3:"${gccount_3}" gccount_2:"${gccount_2}>> ${LOGFILE}
	echo "`loggerDebug` 比较-3 oldgen_2_end:"${oldgen_2_end}" oldgen_3_start:"${oldgen_3_start}>> ${LOGFILE}
	echo "`loggerDebug` 比较-3 gctime_3:"${gctime_3}" gctime_2:"${gctime_2}" gcstamp_3:"${gcstamp_3}" gcstamp_2:"${gcstamp_2}>> ${LOGFILE}
	echo "`loggerDebug` 比较-3 gctime_percent:"${gctime_percent}" heap_percent:"${heap_percent}>> ${LOGFILE}
	#进行比较
	if [ ${gctime_percent} -ge ${targetgctimepercent}  -a  ${heap_percent} -le ${targetheappercent} ]; then
		#条件满足，matchcount+1
		echo "${LOGLEVELDEBUG} 满足-3,进行下一次比较" >> ${LOGFILE}
		matchcount=`expr ${matchcount} + 1`
	else
		#条件不满足，matchcount重置为1
		matchcount=1
		echo "${LOGLEVELDEBUG} 不满足-3,matchcount重置为1" >> ${LOGFILE}
		continue
	fi

	jstatinfo_4=`getNextDiffJstatInfo ${currentpid} ${gccount_3}`
	oldgen_3_end=`echo ${jstatinfo_4}|awk -F\; '{print $2}'`
	gcstamp_4=`echo ${jstatinfo_4}|awk -F\; '{print $1}'|awk '{print $1}'`
	oldgen_4_start=`echo ${jstatinfo_4}|awk -F\; '{print $1}'|awk '{print $9}'`
	gccount_4=`echo ${jstatinfo_4}|awk -F\; '{print $1}'|awk '{print $16}'`
	gctime_4=`echo ${jstatinfo_4}|awk -F\; '{print $1}'|awk '{print $17}'`

	#计算结果为避免进行浮点数比较大小，统一取整
	gctime_percent=`echo "scale=0;(${gctime_4}-${gctime_3})*100/(${gcstamp_4}-${gcstamp_3})"|bc`
	heap_percent=`echo "scale=0;(${oldgen_3_end}-${oldgen_4_start})*100/${oldgensize}"|bc`
	echo "`loggerDebug` 比较-4 gccount_4:"${gccount_4}" gccount_3:"${gccount_3}>> ${LOGFILE}
	echo "`loggerDebug` 比较-4 oldgen_3_end:"${oldgen_3_end}" oldgen_4_start:"${oldgen_4_start}>> ${LOGFILE}
	echo "`loggerDebug` 比较-4 gctime_4:"${gctime_4}" gctime_3:"${gctime_3}" gcstamp_4:"${gcstamp_4}" gcstamp_3:"${gcstamp_3}>> ${LOGFILE}
	echo "`loggerDebug` 比较-4 gctime_percent:"${gctime_percent}" heap_percent:"${heap_percent}>> ${LOGFILE}
	#进行比较
	if [ ${gctime_percent} -ge ${targetgctimepercent}  -a  ${heap_percent} -le ${targetheappercent} ]; then
		#条件满足，matchcount+1
		echo "${LOGLEVELDEBUG} 满足-4,进行下一次比较" >> ${LOGFILE}
		matchcount=`expr ${matchcount} + 1`
	else
		#条件不满足，matchcount重置为1
		matchcount=1
		echo "${LOGLEVELDEBUG} 不满足-4,matchcount重置为1" >> ${LOGFILE}
		continue
	fi


	jstatinfo_5=`getNextDiffJstatInfo ${currentpid} ${gccount_4}`
	oldgen_4_end=`echo ${jstatinfo_5}|awk -F\; '{print $2}'`
	gcstamp_5=`echo ${jstatinfo_5}|awk -F\; '{print $1}'|awk '{print $1}'`
	oldgen_5_start=`echo ${jstatinfo_5}|awk -F\; '{print $1}'|awk '{print $9}'`
	gccount_5=`echo ${jstatinfo_5}|awk -F\; '{print $1}'|awk '{print $16}'`
	gctime_5=`echo ${jstatinfo_5}|awk -F\; '{print $1}'|awk '{print $17}'`

	#计算结果为避免进行浮点数比较大小，统一取整
	gctime_percent=`echo "scale=0;(${gctime_5}-${gctime_4})*100/(${gcstamp_5}-${gcstamp_4})"|bc`
	heap_percent=`echo "scale=0;(${oldgen_4_end}-${oldgen_5_start})*100/${oldgensize}"|bc`
	echo "`loggerDebug` 比较-5 gccount_5:"${gccount_5}" gccount_4:"${gccount_4}>> ${LOGFILE}
	echo "`loggerDebug` 比较-5 oldgen_4_end:"${oldgen_4_end}" oldgen_5_start:"${oldgen_5_start}>> ${LOGFILE}
	echo "`loggerDebug` 比较-5 gctime_5:"${gctime_5}" gctime_4:"${gctime_4}" gcstamp_5:"${gcstamp_5}" gcstamp_4:"${gcstamp_4}>> ${LOGFILE}
	echo "`loggerDebug` 比较-5 gctime_percent:"${gctime_percent}" heap_percent:"${heap_percent}>> ${LOGFILE}
	#进行比较
	if [ ${gctime_percent} -ge ${targetgctimepercent}  -a  ${heap_percent} -le ${targetheappercent} ]; then
		#条件满足，matchcount+1
		echo "${LOGLEVELDEBUG} 满足-5,进行下一次比较" >> ${LOGFILE}
		matchcount=`expr ${matchcount} + 1`
	else
		#条件不满足，matchcount重置为1
		matchcount=1
		echo "${LOGLEVELDEBUG} 不满足-5,matchcount重置为1" >> ${LOGFILE}
		continue
	fi

done

#此时认为即将发生OOM，应该人为进行处理

#后续处理

#调用重启脚本
echo "`loggerInfo` OOM is Thrown !!!重启"${KEYWORD} >> ${LOGFILE}
echo ${RESTARTSCRIPT}|sh
