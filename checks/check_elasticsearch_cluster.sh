#!/bin/bash

ST_OK=0
ST_WR=1
ST_CR=2
ST_UK=3

hostname=localhost
port=9200
warning_total_nodes=4
critical_total_nodes=4
warning_data_nodes=1
critical_data_nodes=1
warning_relocating_shards=0 # Only used in strict mode
critical_relocating_shards=0
warning_initializing_shards=0 # Only used in strict mode
critical_initializing_shards=0
warning_unassigned_shards=0 # Only used in strict mode
critical_unassigned_shards=0
timeout=5

STRICT_MODE_STATUS="WARNING"
STRICT_MODE_CODE=${ST_WR}

# Check dependencies
if ! command -v curl >/dev/null; then
  echo "CRITICAL - curl is not installed"
  exit ${ST_CR}
fi

if ! command -v jq >/dev/null; then
  echo "CRITICAL - jq is not installed"
  exit ${ST_CR}
fi

while test -n "$1"; do
    case "$1" in
        -help|-h)
            print_help
            exit $ST_UK
            ;;
        --hostname|-H)
            hostname=$2
            shift
            ;;
        --port|-P)
            port=$2
            shift
            ;;
        --password|-p)
            password=$2
            authentication=True
            shift
            ;;
        --username|-u)
            username=$2
            authentication=True
            shift
            ;;
        --auth|-a)
            authentication=True
            ;;
        --strict|-s) # TODO: Implement strict_mode
            strict_mode=True
            ;;
        --warning-total-nodes|-w)
            warning_total_nodes=$2
            shift
            ;;
        --critical-total-nodes|-c)
            critical_total_nodes=$2
            shift
            ;;
        --warning-data-nodes|-W)
            warning_data_nodes=$2
            shift
            ;;
        --critical-data-nodes|-C)
            critical_data_nodes=$2
            shift
            ;;
        --timeout|-t)
            timeout=$2
            shift
            ;;
        *)
        echo "Unknown argument: $1"
        print_help
        exit $ST_UK
        ;;
    esac
    shift
done

if [ a"${authentication}" == a"True" ]; then
  user="--user ${user}:${pass}"
fi

get_status() {
  status_page="http://${hostname}:${port}/_cluster/health"

  if ! curl -m ${timeout} -sSL ${user} ${pass} ${status_page} >/dev/null 2>&1; then
    return 1
  fi

  es_status=`curl -m ${timeout} -sSL ${user} ${pass} ${status_page}`
}

get_vals() {
  name=`echo ${es_status} | jq -r .cluster_name`
  status=`echo ${es_status} | jq -r .status`
  number_of_nodes=`echo ${es_status} | jq -r .number_of_nodes`
  number_of_data_nodes=`echo ${es_status} | jq -r .number_of_data_nodes`
  active_primary_shards=`echo ${es_status} | jq -r .active_primary_shards`
  active_shards=`echo ${es_status} | jq -r .active_shards`
  relocating_shards=`echo ${es_status} | jq -r .relocating_shards`
  initializing_shards=`echo ${es_status} | jq -r .initializing_shards`
  unassigned_shards=`echo ${es_status} | jq -r .unassigned_shards`
}

do_output() {
  output="elasticsearch cluster (${name}) is running. \
status=${status} \
number_of_nodes: ${number_of_nodes};w=${warning_total_nodes};c=${critical_total_nodes}; \
number_of_data_nodes: ${number_of_data_nodes};w=${warning_data_nodes};c=${critical_data_nodes}; \
active_primary_shards: ${active_primary_shards}; \
active_shards: ${active_shards}; \
relocating_shards: ${relocating_shards};w=${warning_relocating_shards};c=${critical_relocating_shards}; \
initializing_shards: ${initializing_shards};w=${warning_initializing_shards};c=${critical_initializing_shards}; \
unassigned_shards: ${unassigned_shards};w=${warning_unassigned_shards};c=${critical_unassigned_shards};"
}

do_perfdata() {
  perfdata="'number_of_nodes'=${number_of_nodes} \
'number_of_data_nodes'=${number_of_data_nodes} \
'active_primary_shards'=${active_primary_shards} \
'active_shards'=${active_shards} \
'relocating_shards'=${relocating_shards} \
'initializing_shards'=${initializing_shards} \
'unassigned_shards'=${unassigned_shards} \
"
}

do_exit_status() {
  EXIT_STATUS="OK"
  # Determine the Nagios Status and Exit Code
  ## Strict mode
  if [ a"strict_mode" == a"True" ]; then
    STRICT_MODE_STATUS="CRITICAL"
    STRICT_MODE_CODE=${ST_CR}
  fi

  ## Warnings
  if [ a"status" == "yellow" ]; then
    EXIT_STATUS=${STRICT_MODE_STATUS}
    EXIT_MESSAGE="Cluster (${cluster_name}) is in ${status} status!; ${EXIT_MESSAGE}"
    EXIT_CODE=${STRICT_MODE_CODE}
  fi
  if [ ${number_of_nodes} -lt ${warning_total_nodes} ]; then
    EXIT_STATUS="WARNING"
    EXIT_MESSAGE="Cluster (${cluster_name}) has only ${number_of_nodes} number of nodes!; ${EXIT_MESSAGE}"
    EXIT_CODE=${ST_WR}
  fi
  if [ (($))${active_primary_shards} -lt ${warning_total_nodes} ]; then
    EXIT_STATUS="WARNING"
    EXIT_MESSAGE="Cluster (${cluster_name}) has only ${number_of_nodes} number of nodes!; ${EXIT_MESSAGE}"
    EXIT_CODE=${ST_WR}
  fi


  if [ ${heap_used_percent} -ge ${critical_heap} ]; then
    EXIT_STATUS="CRITICAL"
    EXIT_MESSAGE="Node (${name}) heap usage is ${heap_used_percent} (critical treshold=${critical_heap}); ${EXIT_MESSAGE}"
    EXIT_CODE=${ST_CR}
  elif [ ${heap_used_percent} -ge ${warning_heap} ]; then
    EXIT_STATUS="WARNING"
    EXIT_MESSAGE="Node (${name}) heap usage is ${heap_used_percent} (warning treshold=${warning_heap}); ${EXIT_MESSAGE}"
    EXIT_CODE=${ST_WR}
  fi
  ## Role
  if [ a"${expected_master}" == a"True" -a a"${isMasterNode}" == a"false" ]; then
    EXIT_STATUS="CRITICAL"
    EXIT_MESSAGE="Node (${name}) was expected to be a master node, but it's not!; ${EXIT_MESSAGE}"
    EXIT_CODE=${ST_CR}
  fi
  if [ a"${expected_data}" == a"True" -a a"${isDataNode}" == a"false" ]; then
    EXIT_STATUS="CRITICAL"
    EXIT_MESSAGE="Node (${name})  was expected to be a data node, but it's not!; ${EXIT_MESSAGE}"
    EXIT_CODE=${ST_CR}
  fi
  if [ a"${expected_proxy}" == a"True" -a a"${isProxyNode}" == a"false" ]; then
    EXIT_STATUS="CRITICAL"
    EXIT_MESSAGE="Node (${name})  was expected to be a proxy node, but it's not!; ${EXIT_MESSAGE}"
    EXIT_CODE=${ST_CR}
  fi
}

if ! get_status; then
  echo "CRITICAL - Could not connect to server ${hostname}:${port}"
  exit ${ST_CR}
fi

get_vals

if [ a"${name}" == "a" ]; then
  echo "CRITICAL - Error parsing server output"
  exit ${ST_CR}
fi

do_output
do_perfdata
#do_exit_status

echo "${EXIT_STATUS}: ${EXIT_MESSAGE:-"All good"} - ${output} | ${perfdata}"
exit ${EXIT_CODE}
