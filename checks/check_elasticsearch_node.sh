#!/bin/bash

ST_OK=0
ST_WR=1
ST_CR=2
ST_UK=3

hostname=localhost
port=9200
warning_heap=75
critical_heap=85
timeout=5

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
        --master|-m)
            expected_master=True
            ;;
        --data|-d)
            expected_data=True
            ;;
        --proxy|-x)
            expected_proxy=True
            ;;
        --warning|-w)
            warning_heap=$2
            shift
            ;;
        --critical|-c)
            critical_heap=$2
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

if [ a"${expected_master}" != a"True" -a a"${expected_data}" != a"True" -a a"${expected_proxy}" != a"True" ]; then
  echo "CRITICAL - missing role to check (-m, -d, -x)"
  exit ${ST_CR}
fi

get_status() {
  status_page="http://${hostname}:${port}/_nodes/stats"

  if ! curl -m ${timeout} -sSL ${user} ${pass} ${status_page} >/dev/null 2>&1; then
    return 1
  fi

  # Search using IP
  es_status=`curl -m ${timeout} -sSL ${user} ${pass} ${status_page} | jq .nodes | jq ".[] | select(.ip[] | contains(\"${hostname}\"))" 2>/dev/null`
  if [ $? -ne 0 ]; then
    es_status=`curl -m ${timeout} -sSL ${user} ${pass} ${status_page} | jq .nodes | jq ".[] | select(.ip | contains(\"${hostname}\"))" 2>/dev/null`
  fi
  # Search using Hostname
  if [ a"${es_status}" == "a" ]; then
    es_status=`curl -m ${timeout} -sSL ${user} ${pass} ${status_page} | jq .nodes | jq ".[] | select(.name==\"${hostname}\")"`
  fi
}

get_version() {
  version_page="http://${hostname}:${port}"
  ES_VERSION=`curl -m ${timeout} -sSL ${user} ${pass} ${version_page} | jq -r ".version.number"`
}

get_vals_v1() {
  name=`echo ${es_status} | jq -r .name`
  heap_used_percent=`echo ${es_status} | jq -r .jvm.mem.heap_used_percent`

  isMasterNode=`echo ${es_status} | jq -r .attributes.master | grep -v null`
  isMasterNode=${isMasterNode:-false}
  isDataNode=`echo ${es_status} | jq -r .attributes.data | grep -v null`
  isDataNode=${isDataNode:-true}
  isProxyNode=false
  if [ a"${isMasterNode}" == a"false" -a a"${isDataNode}" == a"false" ]; then
    isProxyNode=true
  fi
}

get_vals_v6() {
  name=`echo ${es_status} | jq -r .name`
  heap_used_percent=`echo ${es_status} | jq -r .jvm.mem.heap_used_percent`

  isMasterNode=`echo ${es_status} | jq -r .roles[] | grep "^master$" | sed "s/master/true/g"`
  isMasterNode=${isMasterNode:-false}
  isDataNode=`echo ${es_status} | jq -r .roles[] | grep "^data$"`
  isDataNode=${isDataNode:-false}
  isProxyNode=false
  if [ a"${isMasterNode}" == a"false" -a a"${isDataNode}" == a"false" ]; then
    isProxyNode=true
  fi
}

do_output() {
  output="elasticsearch (${name}) is running. \
heap_used_percent=${heap_used_percent};w=${warning_heap};c=${critical_heap} \
isMaster: ${isMasterNode}; \
isDataNode: ${isDataNode}; \
isProxyNode: ${isProxyNode}"
}

do_perfdata() {
    perfdata="'heap_used_percent'=${heap_used_percent}%"
}

do_exit_status() {
  EXIT_STATUS="OK"
  # Determine the Nagios Status and Exit Code
  ## Memory
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

get_version
if dpkg --compare-versions ${ES_VERSION} lt 2.0; then
  get_vals_v1
elif dpkg --compare-versions ${ES_VERSION} lt 7.0 ; then
  get_vals_v6
fi

if [ a"${name}" == "a" ]; then
  echo "CRITICAL - Error parsing server output"
  exit ${ST_CR}
fi

do_output
do_perfdata
do_exit_status

echo "${EXIT_STATUS}: ${EXIT_MESSAGE:-"All good"} - ${output} | ${perfdata}"
exit ${EXIT_CODE}

