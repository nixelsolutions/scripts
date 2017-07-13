#!/bin/bash

set -e

export PATH=$PATH:/sbin
SNAPSHOT_PREFIX=autosync
CURRENT_TIME=`date +%Y%m%d-%H:%M:%S`

. /lib/lsb/init-functions

while getopts ":v:m:s:h:d:f:o:" opt; do
   case $opt in
      v)
         VIRTUAL_IP=$OPTARG
      ;;
      m)
         MASTER_IP=$OPTARG
      ;;
      s)
         SLAVE_IP=$OPTARG
      ;;
      h)
         HOURLY_RETENTION=$OPTARG
      ;;
      d)
         DAILY_RETENTION=$OPTARG
      ;;
      f)
         FILESYSTEM=$OPTARG
      ;;
      o)
         OPERATION=`echo $OPTARG | tr '[:upper:]' '[:lower:]'`
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

[ -z "${VIRTUAL_IP}" ] && echo "ERROR: Missing VIRTUAL_IP parameter (-v) - exiting..." && exit 1
[ -z "${MASTER_IP}" ] && echo "ERROR: Missing MASTER_IP parameter (-m) - exiting..." && exit 1
[ -z "${SLAVE_IP}" ] && echo "ERROR: Missing SLAVE_IP parameter (-s) - exiting..." && exit 1
[ -z "${HOURLY_RETENTION}" ] && echo "ERROR: Missing HOURLY_RETENTION parameter (-h) - exiting..." && exit 1
[ -z "${DAILY_RETENTION}" ] && echo "ERROR: Missing DAILY_RETENTION parameter (-d) - exiting..." && exit 1
[ -z "${FILESYSTEM}" ] && echo "ERROR: Missing FILESYSTEM parameter (-f) - exiting..." && exit 1
[ -z "${OPERATION}" ] && echo "ERROR: Missing OPERATION parameter (-o) - exiting..." && exit 1

function check_requisites() {
  # Remove slashes from FILESYSTEM
  FILESYSTEM=${FILESYSTEM%/}
  FILESYSTEM=${FILESYSTEM#/}

  # First condition: VIRTUAL_IP should be assigned locally
  if ! ip addr | grep "inet ${VIRTUAL_IP}/" >/dev/null; then
    echo "INFO: Virtual IP ${VIRTUAL_IP} is not assigned locally, skipping ..."
    exit 0
  fi

  # Now we can find the receiver
  if ip addr | grep "inet ${MASTER_IP}/" >/dev/null; then
    RECEIVER_IP=${SLAVE_IP}
  fi

  if ip addr | grep "inet ${SLAVE_IP}/" >/dev/null; then
    RECEIVER_IP=${MASTER_IP}
  fi

  # Second condition: we should be able to detect the receiver endpoint
  if [ a"${RECEIVER_IP}" == "a" ]; then
    echo "ERROR: I was unable to find the receiver endpoint. Master IP is ${MASTER_IP}, Slave IP is ${SLAVE_IP}, but none is assigned to me?"
    exit 1
  fi

  # Thrid condition: receiver server must be online
  if ! ssh -o "stricthostkeychecking no" ${RECEIVER_IP} "hostname" >/dev/null; then
    echo "ERROR: I was unable to reach receiver IP ${RECEIVER_IP}, giving up ..."
    exit 1
  fi

  # Fourth condition: VIRTUAL_IP should not be assigned on receiver!
  if ssh -o "stricthostkeychecking no" ${RECEIVER_IP} "ip addr | grep \"inet ${VIRTUAL_IP}/\" >/dev/null"; then
    echo "FATAL: Virtual IP ${VIRTUAL_IP} is assigned both to me and receiver! Exiting ..."
    exit 1
  fi

  # Fifth: check that filesystem exists!
  if ! zfs list -H -t filesystem -o name | grep "^${FILESYSTEM}$" >/dev/null; then
    echo "FATAL: Filesystem ${FILESYSTEM} does not exist! Exiting ..."
    exit 1
  fi

  echo "INFO: OK, Virtual IP is ${VIRTUAL_IP}, Receiver IP is ${RECEIVER_IP}, Filesystem is ${FILESYSTEM}"
}

function find_last_snapshot() {
  LAST_SNAPSHOT=`zfs list -H -t snapshot -o name | grep "^${FILESYSTEM}@${SNAPSHOT_PREFIX}-" | sort -n | tail -1`
}

function find_last_snapshot_remote() {
  LAST_SNAPSHOT_REMOTE=`ssh -o "stricthostkeychecking no" ${RECEIVER_IP} "zfs list -H -t snapshot -o name | grep \"^${FILESYSTEM}@${SNAPSHOT_PREFIX}-\" | sort -n | tail -1"`
}

function create_snapshot() {
  find_last_snapshot

  SNAPSHOT_NAME="${SNAPSHOT_PREFIX}-${CURRENT_TIME}"
  if [ a"${SNAPSHOT_NAME}" == "a" ]; then
    echo "FATAL: latest snapshot name is empty! Exiting ..."
    exit 1
  fi
  LATEST_SNAPSHOT="${FILESYSTEM}@${SNAPSHOT_PREFIX}-${CURRENT_TIME}"
  echo "INFO: Creating snapshot ${LATEST_SNAPSHOT}"
  zfs snapshot ${LATEST_SNAPSHOT}

  SNAPSHOT_FILE_PATH=/snapshots/${FILESYSTEM}/${SNAPSHOT_NAME}.gz
  if [ ! -d `dirname ${SNAPSHOT_FILE_PATH}` ]; then
    mkdir -p `dirname ${SNAPSHOT_FILE_PATH}`
  fi
  echo "INFO: Exporting snapshot ${LATEST_SNAPSHOT} to file ${SNAPSHOT_FILE_PATH}"
  if [ a"${LAST_SNAPSHOT}" == "a" ]; then
    zfs send ${LATEST_SNAPSHOT} | gzip > ${SNAPSHOT_FILE_PATH}
  else
    zfs send -i ${LAST_SNAPSHOT} ${LATEST_SNAPSHOT} | gzip > ${SNAPSHOT_FILE_PATH}
  fi
}

function cleanup_latest_snapshot() {
  echo "FATAL: ========> CLEANING UP <========"
  delete_snapshot ${LATEST_SNAPSHOT}
  delete_snapshot_file ${SNAPSHOT_FILE_PATH}
}

function delete_snapshot() {
  local SNAPSHOT=$1
  if [ a"${SNAPSHOT}" == "a" ]; then
    echo "WARNING: I tried to delete a snapshot with empty name! Ignoring ..."
    return
  fi
  if zfs list -H -t snapshot -o name | grep "^${SNAPSHOT}$" >/dev/null; then
    echo "INFO: Deleting snapshot ${SNAPSHOT}"
    zfs destroy ${SNAPSHOT}
  fi
}

function delete_snapshot_remote() {
  local SNAPSHOT=$1
  if [ a"${SNAPSHOT}" == "a" ]; then
    echo "WARNING: I tried to delete a snapshot with empty name on remote ${RECEIVER_IP} ! Ignoring ..."
    return
  fi
  if ssh ${RECEIVER_IP} "zfs list -H -t snapshot -o name | grep \"^${SNAPSHOT}$\"" >/dev/null; then
    echo "INFO: Deleting snapshot ${SNAPSHOT} on remote ${RECEIVER_IP}"
    ssh ${RECEIVER_IP} "zfs destroy ${SNAPSHOT}"
  fi
}

function delete_snapshot_file() {
  local SNAPSHOT_FILE_PATH=$1

  if [ -e ${SNAPSHOT_FILE_PATH} ]; then
    echo "INFO: Deleting latest snapshot file ${SNAPSHOT_FILE_PATH}"
    rm -f ${SNAPSHOT_FILE_PATH}
  fi
}

function send_snapshot_files_to_remote() {
  find_last_snapshot
  LATEST_SNAPSHOT=${LAST_SNAPSHOT}
  find_last_snapshot_remote

  if [ "${LATEST_SNAPSHOT}" == "${LAST_SNAPSHOT_REMOTE}" ]; then
    echo "INFO: Filesystem ${FILESYSTEM} is synced on remote ${RECEIVER_IP} - Latest local snapshot is ${LATEST_SNAPSHOT}, and last remote snapshot is ${LAST_SNAPSHOT_REMOTE}"
    return
  fi

  for local_snapshot in `find /snapshots/${FILESYSTEM}/ -name "${SNAPSHOT_PREFIX}-*.gz" -exec basename {} \; | sort -n`; do
    local_snapshot_date=`echo ${local_snapshot%.*} | awk -F"${SNAPSHOT_PREFIX}-" '{print $2}' | sed "s/-/ /g"`
    local_snapshot_timestamp=`date --date="${local_snapshot_date}" +%s`
    last_snapshot_remote_date=`echo ${LAST_SNAPSHOT_REMOTE} | awk -F"${SNAPSHOT_PREFIX}-" '{print $2}' | sed "s/-/ /g"`
    last_snapshot_remote_timestamp=`date --date="${last_snapshot_remote_date}" +%s`
    local_snapshot=${FILESYSTEM}@${SNAPSHOT_PREFIX}-`echo ${local_snapshot_date} | sed "s/ /-/g"`
    SNAPSHOT_FILE_PATH=/snapshots/${FILESYSTEM}/${SNAPSHOT_PREFIX}-`echo ${local_snapshot_date} | sed "s/ /-/g"`.gz
    if [ ${local_snapshot_timestamp} -le ${last_snapshot_remote_timestamp} ]; then
      delete_snapshot_file ${SNAPSHOT_FILE_PATH}
      continue
    else
      echo "INFO: Sending && applying snapshot file ${SNAPSHOT_FILE_PATH} to remote ${RECEIVER_IP}, filesystem is ${FILESYSTEM}"
      zcat ${SNAPSHOT_FILE_PATH} | ssh ${RECEIVER_IP} "zfs recv ${FILESYSTEM} && zfs rollback ${local_snapshot}"
      #echo "INFO: Applying snapshot ${local_snapshot} on remote ${RECEIVER_IP}"
      #ssh ${RECEIVER_IP} "zfs rollback ${local_snapshot}"
      delete_snapshot_file ${SNAPSHOT_FILE_PATH}
    fi
  done

}

function cleanup_snapshots() {
  OLD_SNAPSHOTS=`zfs list -H -t snapshot -o name | grep "^${FILESYSTEM}@${SNAPSHOT_PREFIX}-" | sort -n | head -n -1`
  for old_snapshot in ${OLD_SNAPSHOTS}; do
    echo "INFO: Deleting old snapshot ${old_snapshot}"
    zfs destroy ${old_snapshot}
  done
}

function list_snapshots_remote() {
  ALL_SNAPSHOTS_REMOTE=`ssh ${RECEIVER_IP} "zfs list -H -t snapshot -o name | grep "^${FILESYSTEM}@${SNAPSHOT_PREFIX}-" | sort -n | head -n -1"`
}

function cleanup_snapshots_remote() {
  DAYS_RETENTION_TIMESTAMP=`date -d "-${DAILY_RETENTION} day" +%s`
  HOURS_RETENTION_TIMESTAMP=`date -d "-${HOURLY_RETENTION} hour" +%s`

  # Delete old snapshots (timestamp < DAYS_RETENTION_TIMESTAMP && timestamp < HOURS_RETENTION_TIMESTAMP)
  list_snapshots_remote
  for SNAPSHOT in ${ALL_SNAPSHOTS_REMOTE}; do
    SNAPSHOT_TIMESTAMP=`date -d "$(echo ${SNAPSHOT} | awk -F"@${SNAPSHOT_PREFIX}-" '{print $2}' | sed "s/-/ /")" +%s`

    if [ ${SNAPSHOT_TIMESTAMP} -lt ${DAYS_RETENTION_TIMESTAMP} -a ${SNAPSHOT_TIMESTAMP} -lt ${HOURS_RETENTION_TIMESTAMP} ]; then
      echo "DEBUG: Snapshot ${SNAPSHOT} is older than DAILY_RETENTION and HOURLY_RETENTION, deleting it"
      delete_snapshot_remote ${SNAPSHOT}
    fi
  done

  # Delete old daily snapshots (timestamp >= DAYS_RETENTION_TIMESTAMP && timestamp < HOURS_RETENTION_TIMESTAMP)
  list_snapshots_remote
  for SNAPSHOT_DAY in `echo "${ALL_SNAPSHOTS_REMOTE}" | awk -F"@${SNAPSHOT_PREFIX}-" '{print $2}' | awk -F- '{print $1}' | sort -n | uniq`; do
    # We add "tail -n +2" to preserve the first daily snapshot
    for SNAPSHOT in `echo "${ALL_SNAPSHOTS_REMOTE}" | grep "\-${SNAPSHOT_DAY}-" | sort -n | tail -n +2`; do
      SNAPSHOT_TIMESTAMP=`date -d "$(echo ${SNAPSHOT} | awk -F"@${SNAPSHOT_PREFIX}-" '{print $2}' | sed "s/-/ /")" +%s`

      if [ ${SNAPSHOT_TIMESTAMP} -ge ${DAYS_RETENTION_TIMESTAMP} -a ${SNAPSHOT_TIMESTAMP} -lt ${HOURS_RETENTION_TIMESTAMP} ]; then
        echo "DEBUG: Snapshot ${SNAPSHOT} is newer than DAILY_RETENTION, but older than HOURLY_RETENTION, deleting it"
        delete_snapshot_remote ${SNAPSHOT}
      fi
    done
  done

  # Delete old hourly snapshots (timestamp >= DAYS_RETENTION_TIMESTAMP && timestamp >= HOURS_RETENTION_TIMESTAMP)
  list_snapshots_remote
  for SNAPSHOT_HOUR in `echo "${ALL_SNAPSHOTS_REMOTE}" | awk -F"@${SNAPSHOT_PREFIX}-" '{print $2}' | awk -F: '{print $1}' | sort -n | uniq`; do
    # We add "tail -n +2" to preserve the first hourly snapshot
    for SNAPSHOT in `echo "${ALL_SNAPSHOTS_REMOTE}" | grep "\-${SNAPSHOT_HOUR}:" | sort -n | tail -n +2`; do
      SNAPSHOT_TIMESTAMP=`date -d "$(echo ${SNAPSHOT} | awk -F"@${SNAPSHOT_PREFIX}-" '{print $2}' | sed "s/-/ /")" +%s`

      if [ ${SNAPSHOT_TIMESTAMP} -ge ${DAYS_RETENTION_TIMESTAMP} -a ${SNAPSHOT_TIMESTAMP} -ge ${HOURS_RETENTION_TIMESTAMP} ]; then
        echo "DEBUG: Snapshot ${SNAPSHOT} is newer than DAILY_RETENTION and HOURLY_RETENTION, deleting it"
        delete_snapshot_remote ${SNAPSHOT}
      fi
    done
  done
}

case ${OPERATION} in
  create_snapshot)
    check_requisites
    # In case of error, we need to delete the last snapshot
    trap "cleanup_latest_snapshot" EXIT
    create_snapshot
    trap - EXIT
    cleanup_snapshots
  ;;
  sync_remote)
    check_requisites
    send_snapshot_files_to_remote
    cleanup_snapshots_remote
  ;;
  delete_remote_snapshots)
    check_requisites
    cleanup_snapshots_remote
  ;;
esac
