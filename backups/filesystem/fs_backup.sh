#!/bin/bash

while getopts ":f:p:r:" opt; do
   case $opt in
      f)
         CFG_FILE="$OPTARG"
      ;;
      p)
         BACKUP_PATH=$OPTARG
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

ME_PATH=`readlink -f "$0"`
ME_DIRNAME=`dirname "$ME_PATH"`
ME_BASENAME=`basename "$ME_PATH"`
ME_FILENAME="${ME_BASENAME%.*}"
[ -z "$CFG_FILE" ] && CFG_FILE="$ME_DIRNAME/$ME_FILENAME.conf"
[ -z "$BACKUP_PATH" ] && echo "ERROR: Missing BACKUP PATH parameter (-p) - exiting..." && exit 1
[ -z "$RETENTION" ] && echo "ERROR: Missing RETENTION parameter (-r) - exiting..." && exit 1

SSH_OPTS+="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
#RSYNC_OPTS+="-e \"ssh $SSH_OPTS\" -avzS"
RSYNC_OPTS+="-avzS"
DATE=`date "+%Y%m%d-%H%M%S"`
BACKUP_TYPE=short
# If sunday, save the backup as long backup
date +%u | grep 7 >/dev/null && BACKUP_TYPE=long

for BACKUP in `cat $CFG_FILE`; do
  echo "Starting processing backup with ID: $BACKUP"

  USER=`echo $BACKUP | awk -F: '{print $1}' | awk -F@ '{print $1}'`
  SERVER=`echo $BACKUP | awk -F: '{print $1}' | awk -F@ '{print $2}'`
  SOURCE_PATH=`echo $BACKUP | awk -F: '{print $2}'`
  DEST_PATH_BASE=$BACKUP_PATH/$SERVER/$BACKUP_TYPE/$DATE
  DEST_PATH=$DEST_PATH_BASE/`basename $SOURCE_PATH`
  LOG_FILE=$DEST_PATH_BASE.log

  if ! ssh $SSH_OPTS -f $USER@$SERVER "hostname" >/dev/null 2>&1; then
     echo "WARNING: Could not reach server $SERVER with user $USER, not backing up backup with ID: $BACKUP"
     continue
  fi

  if [ ! -d $DEST_PATH ]; then
    echo "INFO: Creating destination directory $DEST_PATH ..."
    mkdir -p $DEST_PATH
  fi

  echo "Starting backing up backup with ID: $BACKUP"
  rsync $RSYNC_OPTS -e "ssh $SSH_OPTS" --log-file=$LOG_FILE $USER@$SERVER:$SOURCE_PATH `dirname $DEST_PATH/`
  if [ $? -ne 0 ]; then
    echo "Error backing up backup with ID: $BACKUP ..."
    echo "Deleting directory $DEST_PATH"
    rm -rf $DEST_PATH
    continue
  fi

  echo "Finished backing up backup with ID: $BACKUP ..."
done

for SERVER in `cat $CFG_FILE | awk -F: '{print $1}' | awk -F@ '{print $2}' | sort | uniq`; do
  DEST_PATH_SHORT=$BACKUP_PATH/$SERVER/short
  DEST_PATH_LONG=$BACKUP_PATH/$SERVER/long
  DEST_PATH_BASE=$BACKUP_PATH/$SERVER/$BACKUP_TYPE/$DATE
  DEST_GZIP_FILE=$DEST_PATH_BASE.tar.gz
  LOG_FILE=$DEST_PATH_BASE.log

  echo "Compressing backup directory with ID: $DEST_PATH_BASE on file $DEST_GZIP_FILE ..."
  pushd `dirname $DEST_PATH_BASE`
  tar czf $DEST_GZIP_FILE `basename $LOG_FILE` `basename $DEST_PATH_BASE`
  if [ $? -ne 0 ]; then
    echo "Error compressing directory with ID: $DEST_PATH_BASE ..."
    echo "Deleting file $DEST_GZIP_FILE"
    rm -rf $DEST_GZIP_FILE
    continue
  fi
  echo "Deleting uncompressed backup directory $DEST_PATH_BASE ..."
  rm -rf $LOG_FILE $DEST_PATH_BASE
  popd

  # Delete old backups - short
  SHORT_RETENTION=`echo $RETENTION | awk -F, '{print $1}'`
  echo "Purging short backups on directory $DEST_PATH_SHORT - Retention days = $SHORT_RETENTION"
  /usr/bin/find $DEST_PATH_SHORT -maxdepth 1 -mindepth 1 -mtime +$SHORT_RETENTION -exec rm -rf {} \;

  # Delete old backups - long
  LONG_RETENTION=`echo $RETENTION | awk -F, '{print $2}'`
  echo "Purging long backups on directory $DEST_PATH_LONG - Retention days = $LONG_RETENTION"
  /usr/bin/find $DEST_PATH_LONG -maxdepth 1 -mindepth 1 -mtime +$LONG_RETENTION -exec rm -rf {} \;
done
