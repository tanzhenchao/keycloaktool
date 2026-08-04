#/bin/bash

sourceKeycloakHost="dgrhbk01"
sourcekeycloakConf="/etc/keycloak/keycloak.conf"
targeKeycloakHost="hkrhbk01"
targekeycloakConf="/etc/keycloak/keycloak.conf"

logFile="/var/log/$(basename $0).log"
syncDir="/backup"
backupKeeptime='+7'
keycloakHosts="hkrhbk01 hkrhbk02"
sshUser="root"
serviceName="keycloak"

tigaseAppID="10086"
tigaseAppPassword="*********"
tigaseEmployeeID="will,jeff"
tigaseApiURL="https://tigase.cmdschool.org:8092/tigase/pushText"

parameter1="$1"
parameter2="$2"

getDBConf() {
  local conf=$(cat)
  local dbType=$(echo "$conf" | awk -F= '/^[[:space:]]*db[[:space:]]*=/{gsub(/[ \t]/,"",$2);print $2}')
  local dbUser=$(echo "$conf" | awk -F= '/^[[:space:]]*db-username[[:space:]]*=/{gsub(/[ \t]/,"",$2);print $2}')
  local dbPass=$(echo "$conf" | awk -F= '/^[[:space:]]*db-password[[:space:]]*=/{gsub(/[ \t]/,"",$2);print $2}')
  local dbUrl=$(echo "$conf" | awk -F= '/^[[:space:]]*db-url[[:space:]]*=/{sub(/^[ \t]+/,"",$2);print $2}')

  if [[ $dbUrl =~ jdbc:[^:]+://([^:/]+):([0-9]+)/([^?]+) ]]; then
    dbHost="${BASH_REMATCH[1]}"
    dbPort="${BASH_REMATCH[2]}"
    dbName="${BASH_REMATCH[3]}"
  fi

  echo "dbType:$dbType"
  echo "dbUser:$dbUser"
  echo "dbPass:$dbPass"
  echo "dbHost:$dbHost"
  echo "dbPort:$dbPort"
  echo "dbName:$dbName"
}

syncDB() {
  local sourceDBType="$1"
  local sourceDBUser="$2"
  local sourceDBPass="$3"
  local sourceDBHost="$4"
  local sourceDBPort="$5"
  local sourceDBName="$6"

  local targetDBType="$7"
  local targetDBUser="$8"
  local targetDBPass="$9"
  local targetDBHost="${10}"
  local targetDBPort="${11}"
  local targetDBName="${12}"

  # Validate parameters
  if [ -z "$sourceDBHost" ] || [ -z "$targetDBHost" ]; then
    echo "$(date +%Y-%m-%d-%H:%M:%S) [ERROR] Database connection parameters cannot be empty." | tee -a "$logFile"
    return 1
  fi

  local dumpFile="$syncDir/sourceBackup_${sourceDBName}_$(date +%Y%m%d%H%M%S).sql"

  #find "$syncDir" -mtime "$backupKeeptime" -type f -name "sourceBackup_${sourceDBName}_*.sql*" -exec ls -l {} \;
  find "$syncDir" -mtime "$backupKeeptime" -type f -name "sourceBackup_${sourceDBName}_*.sql*" -exec rm -f {} \;

  # Export source database
  mysqldump -h"$sourceDBHost" -P"$sourceDBPort" -u"$sourceDBUser" -p"$sourceDBPass" "$sourceDBName" > "$dumpFile"
  if [ $? -ne 0 ]; then
    echo "$(date +%Y-%m-%d-%H:%M:%S) [ERROR] Failed to export source database: ${sourceDBName}" | tee -a "$logFile"
    return 2
  fi

  # Import into target database
  mysql -h"$targetDBHost" -P"$targetDBPort" -u"$targetDBUser" -p"$targetDBPass" "$targetDBName" < "$dumpFile"
  if [ $? -ne 0 ]; then
    echo "$(date +%Y-%m-%d-%H:%M:%S) [ERROR] Failed to import data into target database: ${targetDBName}" | tee -a "$logFile"
    return 3
  fi

  if [ -f "$dumpFile" ]; then
    gzip "$dumpFile"
  fi

  echo "$(date +%Y-%m-%d-%H:%M:%S) [INFO] Database synchronization completed successfully: '${sourceDBHost}:${sourceDBName}' -> '${targetDBHost}:${targetDBName}'" | tee -a "$logFile"
  return 0
}

backupTargetDB() {
  local targetDBType="$1"
  local targetDBUser="$2"
  local targetDBPass="$3"
  local targetDBHost="$4"
  local targetDBPort="$5"
  local targetDBName="$6"

  # Validate parameters
  if [ -z "$targetDBHost" ] || [ -z "$targetDBName" ]; then
    echo "$(date +%Y-%m-%d-%H:%M:%S) [ERROR] Database backup parameters cannot be empty." | tee -a "$logFile"
    return 1
  fi

  local backupFile="$syncDir/targeBackup_${targetDBName}_$(date +%Y%m%d%H%M%S).sql"

  # Clean expired backup files
  #find "$syncDir" -mtime +"$backupKeeptime" -type f -name "targeBackup_${targetDBName}_*.sql" -exec ls {} \;
  find "$syncDir" -mtime +"$backupKeeptime" -type f -name "targeBackup_${targetDBName}_*.sql" -exec rm -f {} \;

  # Backup database
  mysqldump -h"$targetDBHost" -P"$targetDBPort" -u"$targetDBUser" -p"$targetDBPass" "$targetDBName" > "$backupFile"

  if [ $? -ne 0 ]; then
    echo "$(date +%Y-%m-%d-%H:%M:%S) [ERROR] Failed to back up database: ${targetDBName}" | tee -a "$logFile"
    return 2
  fi

  if [ -f "$backupFile" ]; then
    gzip "$backupFile"
  fi
  echo "$(date +%Y-%m-%d-%H:%M:%S) [INFO] Database backup completed successfully: ${backupFile}.gz" | tee -a "$logFile"
  return 0
}

remoteExec() {
    local host=$1
    local user=$2
    shift 2

    ssh -o ConnectTimeout=10 "${user}@${host}" "$@"
}

stopService() {
    local host=$1
    local user=$2
    local service=$3

    if ! remoteExec "$host" "$user" "systemctl is-active --quiet $service"; then
        echo "$(date +%Y-%m-%d-%H:%M:%S) [INFO] $service is not running on $host" | tee -a "$logFile"
        return 0
    fi

    echo "$(date +%Y-%m-%d-%H:%M:%S) [INFO] Stopping $service on $host..." | tee -a "$logFile"

    if ! remoteExec "$host" "$user" "sudo systemctl stop $service"; then
        echo "$(date +%Y-%m-%d-%H:%M:%S) [ERROR] Failed to stop $service on $host" | tee -a "$logFile"
        return 1
    fi

    for ((i=0; i<30; i++)); do
        if ! remoteExec "$host" "$user" "systemctl is-active --quiet $service"; then
            echo "$(date +%Y-%m-%d-%H:%M:%S) [INFO] $service stopped successfully on $host" | tee -a "$logFile"
            return 0
        fi
        sleep 1
    done

    echo "$(date +%Y-%m-%d-%H:%M:%S) [ERROR] Timeout waiting for $service to stop on $host" | tee -a "$logFile"
    return 2
}

startService() {
    local host=$1
    local user=$2
    local service=$3

    if remoteExec "$host" "$user" "systemctl is-active --quiet $service"; then
        echo "$(date +%Y-%m-%d-%H:%M:%S) [INFO] $service is already running on $host" | tee -a "$logFile"
        return 0
    fi

    echo "$(date +%Y-%m-%d-%H:%M:%S) [INFO] Starting $service on $host..." | tee -a "$logFile"

    if ! remoteExec "$host" "$user" "sudo systemctl start $service"; then
        echo "$(date +%Y-%m-%d-%H:%M:%S) [ERROR] Failed to start $service on $host" | tee -a "$logFile"
        return 1
    fi

    for ((i=0; i<30; i++)); do
        if remoteExec "$host" "$user" "systemctl is-active --quiet $service"; then
            echo "$(date +%Y-%m-%d-%H:%M:%S) [INFO] $service started successfully on $host" | tee -a "$logFile"
            return 0
        fi
        sleep 1
    done

    echo "$(date +%Y-%m-%d-%H:%M:%S) [ERROR] Timeout waiting for $service to start on $host" | tee -a "$logFile"
    return 2
}

checkService() {
    local host=$1
    local user=$2
    local service=$3

    if remoteExec "$host" "$user" "systemctl is-active --quiet $service"; then
        echo "$service is running on $host"
        return 0
    else
        echo "$service is not running on $host"
        return 1
    fi
}

urlencode() {
    python3 -c "import sys, urllib.parse as ul; print(ul.quote_plus(sys.argv[1]))" "$@"
}

msg2Tigase() {
  local tigaseEmployeeID="$1"
  local logMessage="$2"

  encodeMessage=$(urlencode "$logMessage")
  tigaseMessageBody="$encodeMessage"
  curlData="appId=$tigaseAppID&password=$tigaseAppPassword&employee_id=$tigaseEmployeeID&body=$tigaseMessageBody"
  curl -X POST -d "$curlData" "$tigaseApiURL" &> /dev/null
}

backupKeycloakDB() {
  targeKeycloakVars=$(ssh "$targeKeycloakHost" cat "$targekeycloakConf" | getDBConf)

  targeDBUser=$(echo "$targeKeycloakVars" | grep "^dbUser" | awk -F':' '{print $2}')
  targeDBPass=$(echo "$targeKeycloakVars" | grep "^dbPass" | awk -F':' '{print $2}')
  targeDBHost=$(echo "$targeKeycloakVars" | grep "^dbHost" | awk -F':' '{print $2}')
  targeDBPort=$(echo "$targeKeycloakVars" | grep "^dbPort" | awk -F':' '{print $2}')
  targeDBType=$(echo "$targeKeycloakVars" | grep "^dbType" | awk -F':' '{print $2}')
  targeDBName=$(echo "$targeKeycloakVars" | grep "^dbName" | awk -F':' '{print $2}')

  backupTargetDB "$targeDBType" "$targeDBUser" "$targeDBPass" "$targeDBHost" "$targeDBPort" "$targeDBName"
  return $?
}

syncKeycloakDB() {
  sourceKeycloakVars=$(ssh "$sourceKeycloakHost" cat "$sourcekeycloakConf" | getDBConf)
  targeKeycloakVars=$(ssh "$targeKeycloakHost" cat "$targekeycloakConf" | getDBConf)

  sourceDBType=$(echo "$sourceKeycloakVars" | grep "^dbType" | awk -F':' '{print $2}')
  sourceDBUser=$(echo "$sourceKeycloakVars" | grep "^dbUser" | awk -F':' '{print $2}')
  sourceDBPass=$(echo "$sourceKeycloakVars" | grep "^dbPass" | awk -F':' '{print $2}')
  sourceDBHost=$(echo "$sourceKeycloakVars" | grep "^dbHost" | awk -F':' '{print $2}')
  sourceDBPort=$(echo "$sourceKeycloakVars" | grep "^dbPort" | awk -F':' '{print $2}')
  sourceDBName=$(echo "$sourceKeycloakVars" | grep "^dbName" | awk -F':' '{print $2}')

  targeDBUser=$(echo "$targeKeycloakVars" | grep "^dbUser" | awk -F':' '{print $2}')
  targeDBPass=$(echo "$targeKeycloakVars" | grep "^dbPass" | awk -F':' '{print $2}')
  targeDBHost=$(echo "$targeKeycloakVars" | grep "^dbHost" | awk -F':' '{print $2}')
  targeDBPort=$(echo "$targeKeycloakVars" | grep "^dbPort" | awk -F':' '{print $2}')
  targeDBType=$(echo "$targeKeycloakVars" | grep "^dbType" | awk -F':' '{print $2}')
  targeDBName=$(echo "$targeKeycloakVars" | grep "^dbName" | awk -F':' '{print $2}')

  syncDB "$sourceDBType" "$sourceDBUser" "$sourceDBPass" "$sourceDBHost" "$sourceDBPort" "$sourceDBName" "$targeDBType" "$targeDBUser" "$targeDBPass" "$targeDBHost" "$targeDBPort" "$targeDBName"
  return $?
}

autoSyncKeycloakDB() {
  sendMsg=$1

  if [ -z "$sendMsg" ];then
    sendMsg=0
  fi

  backuTargetDBStatus=0
  syncDBStatus=0
  stopServiceStatus=0
  startServiceStatus=0

  stopKeycloak "$keycloakHosts"
  if [ $? -ne 0 ]; then
    stopServiceStatus=1
  fi

  if [ $stopServiceStatus -eq 0 ]; then
    backupKeycloakDB
    if [ $? -ne 0 ]; then
      backuTargetDBStatus=1
    else
      syncKeycloakDB
      if [ $? -ne 0 ]; then
        syncDBStatus=1
      fi
    fi
  fi

  startKeycloak "$keycloakHosts"
  if [ $? -ne 0 ]; then
    startServiceStatus=1
  fi

  totalStatus=$((backuTargetDBStatus + syncDBStatus + stopServiceStatus + startServiceStatus))
  if [ "$totalStatus" -eq 0 ]; then
    exit 0
  fi
  if [ "$sendMsg" -eq 0 ];then
    exit 0
  fi
  logMessage="Websso HA Sync Failed:"$'\n'"please check log file $logFile on $(hostname -s)"
  msg2Tigase "$tigaseEmployeeID" "$logMessage"
}

stopKeycloak() {
  local serviceHosts="$1"

  stopServiceStatus=0
  for serviceHost in $serviceHosts; do
    stopService "$serviceHost" "$sshUser" "$serviceName"
    if [ $? -ne 0 ]; then
	stopServiceStatus=1
    fi
  done
  return $stopServiceStatus
}

startKeycloak() {
  local serviceHosts="$1"

  startServiceStatus=0
  for serviceHost in $serviceHosts; do
    startService "$serviceHost" "$sshUser" "$serviceName"
    if [ $? -ne 0 ]; then
	startServiceStatus=1
    fi
  done
  return $startServiceStatus
}

checkKeycloak() {
  local serviceHosts="$1"

  checkServiceStatus=0
  for serviceHost in $serviceHosts; do
    checkService "$serviceHost" "$sshUser" "$serviceName"
    if [ $? -ne 0 ]; then
	checkServiceStatus=1
    fi
  done
  return $checkServiceStatus
}

case "$parameter1" in
  keycloak)
    case "$parameter2" in
      stop)
            stopKeycloak "$keycloakHosts"
            ;;
      start)
            startKeycloak "$keycloakHosts"
            ;;
      status)
            checkKeycloak "$keycloakHosts"
            ;;
      *)
            echo "Usage: $0 keycloak {stop|start|status}"
            ;;
      esac
      ;;
    db)
      case "$parameter2" in
        backup)
             backupKeycloakDB
             ;;
        sync)
             syncKeycloakDB
             ;;
        autosync)
             autoSyncKeycloakDB 1
             ;;
        *)
             echo "Usage: $0 db {backup|sync|autosync}"
             ;;
        esac
        ;;
    *)
        echo "Usage: $0 {keycloak|db}"
        ;;
esac
exit 0
