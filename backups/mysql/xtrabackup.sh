#!/bin/bash

while getopts ":s:p:d:r:" opt; do
   case $opt in
      s)
         MYSQL_SERVERS=$OPTARG
      ;;
      p)
         MYSQL_BACKUP_PATH=$OPTARG
      ;;
      d)
         MYSQL_DBS=`echo $OPTARG | sed 's/,/ /g'`
      ;;
      r)
         RETENTION=$OPTARG
      ;;
      \?)
         echo "Invalid option: -$OPTARG" >&2
         exit 1
      ;;
      :)
         echo "Option -$OPTARG requires an argument." >&2
         exit 1
      ;;
   esac
done

[ -z "$MYSQL_SERVERS" ] && echo "ERROR: Missing MySQL SERVERS parameter (-s) - exiting..." && exit 1
[ -z "$MYSQL_BACKUP_PATH" ] && echo "ERROR: Missing MySQL BACKUP PATH parameter (-p) - exiting..." && exit 1
[ -z "$MYSQL_DBS" ] && echo "ERROR: Missing MySQL DBS parameter (-d) - exiting..." && exit 1
[ -z "$RETENTION" ] && echo "ERROR: Missing RETENTION parameter (-r) - exiting..." && exit 1

MYSQL_CFG_FILE=/etc/my.cnf
MYSQL_USER="CHANGEME"
MYSQL_PASSWORD="CHANGEME"
ENCRYPT_PASSWORD="CHANGEME"

EXCLUDE_DATABASES="information_schema"
ENCRYPT_PASSWORD_FILE=`dirname $0`/`basename ${0%.*}`.encrypt

# Check connectivity with servers
for SERVER in $MYSQL_SERVERS; do
   echo "Testing connectivity with server $SERVER ..."
   echo "SELECT 1 FROM DUAL" | mysql --defaults-file=$MYSQL_CFG_FILE -B -s -h $SERVER -u $MYSQL_USER -p$MYSQL_PASSWORD >/dev/null 2>&1
   if [ $? -eq 0 ]; then
      MYSQL_SERVER=$SERVER
      echo "Server $MYSQL_SERVER is up, using this server for backing up..."
      break
   else
      echo "Could not connect to server $SERVER - Trying another one..."
   fi
done

[ -z "$MYSQL_SERVER" ] && echo "ERROR: Could not contact any of these servers: $MYSQL_SERVERS - Skipping backup..." && exit 1

# If selected all databases, just select them from show databases
[ "$MYSQL_DBS" = "all" ] && MYSQL_DBS=`echo "SHOW DATABASES" | $MYSQL_BIN_PATH/mysql --defaults-file=$MYSQL_CFG_FILE -B -s -h $MYSQL_SERVER -u $MYSQL_USER | tr '\n' ' '`
[ -z "$MYSQL_DBS" ] && echo "ERROR: Could not obtain a database list from MySQL instance $MYSQL_INSTANCE - exiting..." && exit 1

# Exclude databases
for excludeDb in $EXCLUDE_DATABASES; do
   MYSQL_DBS=`echo $MYSQL_DBS | sed "s/$excludeDb//g"`
done

BKP_PATH=$MYSQL_BACKUP_PATH/`date +%Y`/`date +%m`/`date +%d`/`date +%H%M%S`
BKP_LOGFILE=`dirname $BKP_PATH`/backup.`basename $BKP_PATH`.log
BKP_FILE_EXTENSION=tar.gz.encrypt
BKP_FILE_PATH=${BKP_PATH}.${BKP_FILE_EXTENSION}

if [ ! -d `dirname $BKP_PATH` ]; then
  mkdir -p `dirname $BKP_PATH`
  [ $? -ne 0 ] && echo "ERROR: Could not create directory `dirname $BKP_PATH` - exiting..." && exit 1
fi

innobackupex --defaults-file=$MYSQL_CFG_FILE --no-lock --host=$MYSQL_SERVER --user="$MYSQL_USER" --password="$MYSQL_PASSWORD" --databases="$MYSQL_DBS" --rsync $BKP_PATH --no-timestamp > $BKP_LOGFILE 2>&1
if [ $? -ne 0 ]; then
   echo "Error backing up databases $MYSQL_DBS ..."
   echo "Deleting backup directory $BKP_PATH ..."
   rm -f $BKP_PATH
   exit 1
fi

mv $BKP_LOGFILE $BKP_PATH/

# Prepare ENCRYPT_PASSWORD_FILE
# This is the safest way to put password in file (so it's not shown in ps list)
umask 277
rm -f $ENCRYPT_PASSWORD_FILE
cat >$ENCRYPT_PASSWORD_FILE <<EOM
$ENCRYPT_PASSWORD
EOM

# Package, compress and encrypt backup
tar zcvf - -C `dirname $BKP_PATH` `basename $BKP_PATH` | openssl aes-256-cbc -salt -pass file:$ENCRYPT_PASSWORD_FILE > $BKP_FILE_PATH
if [ $? -ne 0 ]; then
   echo "Error packaging backup directgory $BKP_PATH ..."
   echo "Deleting backup file $BKP_FILE_PATH ..."
   rm -f $BKP_FILE_PATH
   rm -f $ENCRYPT_PASSWORD_FILE
   exit 1
fi

# Delete uncompressed and unencrypted backup
rm -rf $BKP_PATH

rm -f $ENCRYPT_PASSWORD_FILE

# Delete old backups
/usr/bin/find $MYSQL_BACKUP_PATH -type f -name "*.$BKP_FILE_EXTENSION" -mtime +$RETENTION -exec rm -f {} \;
