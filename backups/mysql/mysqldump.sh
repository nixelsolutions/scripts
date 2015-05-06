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

MYSQL_CFG_FILE=/etc/my.cnf
MYSQL_USER="CHANGEME"
MYSQL_PASSWORD="CHANGEME"
ENCRYPT_PASSWORD="CHANGEME"

EXCLUDE_DATABASES="information_schema performance_schema"
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
[ "$MYSQL_DBS" = "all" ] && MYSQL_DBS=`echo "SHOW DATABASES" | mysql --defaults-file=$MYSQL_CFG_FILE -B -s -h $MYSQL_SERVER -u $MYSQL_USER -p$MYSQL_PASSWORD | tr '\n' ' '`
[ -z "$MYSQL_DBS" ] && echo "ERROR: Could not obtain a database list from MySQL instance $MYSQL_INSTANCE - exiting..." && exit 1

# Exclude databases
for excludeDb in $EXCLUDE_DATABASES; do
   MYSQL_DBS=`echo $MYSQL_DBS | sed "s/$excludeDb//g"`
done

# Prepare ENCRYPT_PASSWORD_FILE
# This is the safest way to put password in file (so it's not shown in ps list)
umask 277
rm -f $ENCRYPT_PASSWORD_FILE
cat >$ENCRYPT_PASSWORD_FILE <<EOM
$ENCRYPT_PASSWORD
EOM

for db in $MYSQL_DBS; do
  DATE=`date +%Y%m%d-%H%M%S`

  BKP_FILENAME=$MYSQL_BACKUP_PATH/$db/$db.$DATE
  BKP_FILE_EXTENSION=sql.gz.encrypted
  BKP_FILE_PATH=${BKP_FILENAME}.${BKP_FILE_EXTENSION}
  BKP_PATH=`dirname $BKP_FILE_PATH`

  if [ ! -d $BKP_PATH ]; then
    mkdir -p $BKP_PATH
    [ $? -ne 0 ] && echo "ERROR: Could not create directory $BKP_PATH - exiting..." && exit 1
  fi

  mysqldump --defaults-file=$MYSQL_CFG_FILE -h $MYSQL_SERVER -u $MYSQL_USER -p$MYSQL_PASSWORD --skip-lock-tables $db | gzip - | openssl aes-256-cbc -salt -pass file:$ENCRYPT_PASSWORD_FILE > $BKP_FILE_PATH
  if [ $? -ne 0 ]; then
     echo "Error backing up database $db ..."
     echo "Deleting file $BKP_FILE_PATH ..."
     rm -f $BKP_FILE_PATH
     rm -f $ENCRYPT_PASSWORD_FILE
     exit 1
  fi

  # Delete old backups
  /usr/bin/find $MYSQL_BACKUP_PATH/$db -type f -name "$db.*.$BKP_FILE_EXTENSION" -mtime +$RETENTION -exec rm -f {} \;
done

rm -f $ENCRYPT_PASSWORD_FILE
