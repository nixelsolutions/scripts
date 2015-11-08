#!/bin/bash

while getopts ":s:p:d:r:" opt; do
   case $opt in
      s)
         MYSQL_SERVERS="$OPTARG"
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

#MYSQL_CFG_FILE=/etc/mysql/backups.cnf
MYSQL_USER=CHANGEME
MYSQL_PASSWORD=CHANGEME

EXCLUDE_DATABASES="information_schema performance_schema"

# ENABLE THIS ONLY IF YOU HAVE FLUSH GRANTS
#MYSQLDUMP_EXTRA="--single-transaction --flush-logs --hex-blob --master-data=2"
[ ! -z ${MYSQL_CFG_FILE} ] && MYSQLDUMP_EXTRA="--defaults-file=${MYSQL_CFG_FILE} ${MYSQLDUMP_EXTRA}"
[ ! -z ${MYSQL_PASSWORD} ] && MYSQLDUMP_EXTRA="-p$MYSQL_PASSWORD ${MYSQLDUMP_EXTRA}"

# Check connectivity with servers
for SERVER in `echo $MYSQL_SERVERS | sed "s/,/ /g"`; do
   echo "Testing connectivity with server $SERVER ..."
   echo "SELECT 1 FROM DUAL" | mysql -B -s -h $SERVER -u $MYSQL_USER -p$MYSQL_PASSWORD >/dev/null 2>&1
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
[ "$MYSQL_DBS" = "all" ] && MYSQL_DBS=`echo "SHOW DATABASES" | mysql -B -s -h $MYSQL_SERVER -u $MYSQL_USER -p$MYSQL_PASSWORD | tr '\n' ' '`
[ -z "$MYSQL_DBS" ] && echo "ERROR: Could not obtain a database list from MySQL instance $MYSQL_INSTANCE - exiting..." && exit 1

# Exclude databases
for excludeDb in $EXCLUDE_DATABASES; do
   MYSQL_DBS=`echo $MYSQL_DBS | sed "s/$excludeDb//g"`
done

for db in $MYSQL_DBS; do
  DATE=`date +%Y%m%d-%H%M%S`

  BKP_SHORT_DIR=$MYSQL_BACKUP_PATH/short/$db
  BKP_LONG_DIR=$MYSQL_BACKUP_PATH/long/$db
  BKP_FILENAME=$BKP_SHORT_DIR/$db.$DATE
  # If sunday, save the backup as long backup
  date +%u | grep 7 >/dev/null && BKP_FILENAME=$BKP_LONG_DIR/$db.$DATE
  BKP_FILE_EXTENSION=sql.gz
  BKP_FILE_PATH=${BKP_FILENAME}.${BKP_FILE_EXTENSION}
  BKP_PATH=`dirname $BKP_FILE_PATH`

  if [ ! -d $BKP_SHORT_DIR ]; then
    mkdir -p $BKP_SHORT_DIR
    [ $? -ne 0 ] && echo "ERROR: Could not create directory $BKP_SHORT_DIR - exiting..." && exit 1
  fi

  if [ ! -d $BKP_LONG_DIR ]; then
    mkdir -p $BKP_LONG_DIR
    [ $? -ne 0 ] && echo "ERROR: Could not create directory $BKP_LONG_DIR - exiting..." && exit 1
  fi

  mysqldump --skip-lock-tables -h $MYSQL_SERVER -u $MYSQL_USER "${MYSQLDUMP_EXTRA}" $db | gzip - > $BKP_FILE_PATH
  if [ $? -ne 0 ]; then
     echo "Error backing up database $db ..."
     echo "Deleting file $BKP_FILE_PATH ..."
     rm -f $BKP_FILE_PATH
     exit 1
  fi

  # Delete old backups - short
  SHORT_RETENTION=`echo $RETENTION | awk -F, '{print $1}'`
  /usr/bin/find $BKP_SHORT_DIR -type f -name "$db.*.$BKP_FILE_EXTENSION" -mtime +$SHORT_RETENTION -exec rm -f {} \;

  # Delete old backups - long
  LONG_RETENTION=`echo $RETENTION | awk -F, '{print $2}'`
  /usr/bin/find $BKP_LONG_DIR -type f -name "$db.*.$BKP_FILE_EXTENSION" -mtime +$LONG_RETENTION -exec rm -f {} \;
done
