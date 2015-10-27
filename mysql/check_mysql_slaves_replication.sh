#!/bin/bash

EXIT_OK=0
EXIT_WARNING=1
EXIT_CRITICAL=2
EXIT_UNKNOWN=3

# Params:
# -h HOSTS
# -t TIMEOUT
# -u USER
# -p PASSWORD

while getopts ":b:h:t:u:p:wc" PARAMS; do
      case $PARAMS in
      b)
           MYSQL_BIN=$OPTARG
           ;;
      h)
           HOSTS=$OPTARG
           ;;
      t)
           TIMEOUT=$OPTARG
           ;;
      u)
           EXEC_USER=$OPTARG
           ;;
      p)
           EXEC_PASSWORD=$OPTARG
           ;;
      w)
           WARNING_SECONDS_BEHIND_MASTER=$OPTARG
           ;;
      c)
           CRITICAL_SECONDS_BEHIND_MASTER=$OPTARG
           ;;
      esac
done

[ -z $MYSQL_BIN ] && echo "Error, mysql binary is missing (parameter -b)" && exit $EXIT_UNKNOWN
[ -z $HOSTS ] && echo "Error, host is missing (parameter -h)" && exit $EXIT_UNKNOWN
[ -z $TIMEOUT ] && TIMEOUT=15
[ -z $EXEC_USER ] && echo "Error, user parameter is missing (parameter -u)" && exit $EXIT_UNKNOWN
[ -z $EXEC_PASSWORD ] && echo "Error, password parameter is missing (parameter -p)" && exit $EXIT_UNKNOWN
[ -z $WARNING_SECONDS_BEHIND_MASTER ] && WARNING_SECONDS_BEHIND_MASTER=1
[ -z $CRITICAL_SECONDS_BEHIND_MASTER ] && CRITICAL_SECONDS_BEHIND_MASTER=10

EXIT_MSG=""
EXIT_CODE=$EXIT_OK
SSH_OPTIONS="-p 2222 -oBatchMode=yes -oConnectTimeout=$TIMEOUT"

for mysqlServer in `echo $HOSTS | sed 's/,/ /g'`; do
    # Connect to mysql server and execute "show slave status" query
    MYSQL_STATUS=`echo "show slave status \G" | $MYSQL_BIN --show-warnings=FALSE --connect-timeout=$TIMEOUT -u $EXEC_USER -p$EXEC_PASSWORD -h $mysqlServer 2>&1`
    if [ $? -ne 0 ]; then
       echo -e "Error connecting to MySQL server on node $mysqlServer... Error was: $MYSQL_STATUS\n"
       exit $EXIT_CRITICAL
    else
       # Check replication desfase
       SEC_BEHIND_MASTER=`echo -e "$MYSQL_STATUS" | grep "Seconds_Behind_Master: " | awk '{print $2}'`
       if [ $SEC_BEHIND_MASTER == "NULL" ]; then
          EXIT_CODE=$EXIT_CRITICAL
       else
          [ $SEC_BEHIND_MASTER -gt $WARNING_SECONDS_BEHIND_MASTER ] && EXIT_CODE=$EXIT_WARNING
          [ $SEC_BEHIND_MASTER -gt $CRITICAL_SECONDS_BEHIND_MASTER ] && EXIT_CODE=$EXIT_CRITICAL
       fi
       # Look for errors in status... find and report them
       echo -e "$MYSQL_STATUS" | grep "Last.*Errno: " | grep -v "Errno: 0" >/dev/null
       if [ $? -eq 0 ]; then
          for errorNumber in `echo -e "$MYSQL_STATUS" | grep "Last.*Errno: " | grep -v "Errno: 0" | awk -F: '{print $1}'`; do
              ERROR_TYPE=`echo $errorNumber | sed 's/Errno/Error/g'`
              ERROR_MSGS=`echo -e "$MYSQL_STATUS" | grep "$ERROR_TYPE:"`
              EXIT_MSG="Error found in slave $mysqlServer: $ERROR_MSGS\n$EXIT_MSG"
              EXIT_CODE=$EXIT_CRITICAL
          done
       else
          [ $EXIT_CODE -eq $EXIT_OK ] && EXIT_MSG="OK: MySQL servers $HOSTS are synced"
       fi
    fi
done

echo -e "$EXIT_MSG. Seconds Behind Master: $SEC_BEHIND_MASTER"
exit $EXIT_CODE
