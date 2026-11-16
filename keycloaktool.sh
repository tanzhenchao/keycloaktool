#/bin/bash

syncSourceHost="dgrhbk01"
syncSourceConf="/etc/keycloak/keycloak.conf"
syncTargeHost="hkrhbk01"
syncTargeConf="/etc/keycloak/keycloak.conf"

logFile="/var/log/$(basename $0).log"
syncDir="/backup"
backupKeeptime='+7'
sourceKeycloakHosts="dgrhbk01 dgrhbk02"
targetKeycloakHosts="hkrhbk01 hkrhbk02"
sshUser="root"
serviceName="keycloak"

tigaseAppID="10086"
tigaseAppPassword="*********"
tigaseEmployeeID="will,jeff"
tigaseApiURL="https://tigase.cmdschool.org:8092/tigase/pushText"

keycloakUrl="https://websso.cmdschool.org"
keycloakAdmin="admin"
keycloakPassword="adminpwd"

parameter1="$1"
parameter2="$2"
parameter3="$3"

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
    echo "$(date +'%Y-%m-%d %H:%M:%S') [ERROR] Database connection parameters cannot be empty." | tee -a "$logFile"
    return 1
  fi

  local dumpFile="$syncDir/sourceBackup_${sourceDBName}_$(date +%Y%m%d%H%M%S).sql"

  #find "$syncDir" -mtime "$backupKeeptime" -type f -name "sourceBackup_${sourceDBName}_*.sql*" -exec ls -l {} \;
  find "$syncDir" -mtime "$backupKeeptime" -type f -name "sourceBackup_${sourceDBName}_*.sql*" -exec rm -f {} \;

  # Export source database
  mysqldump -h"$sourceDBHost" -P"$sourceDBPort" -u"$sourceDBUser" -p"$sourceDBPass" "$sourceDBName" > "$dumpFile"
  if [ $? -ne 0 ]; then
    echo "$(date +'%Y-%m-%d %H:%M:%S') [ERROR] Failed to export source database: ${sourceDBName}" | tee -a "$logFile"
    return 2
  fi

  # Import into target database
  mysql -h"$targetDBHost" -P"$targetDBPort" -u"$targetDBUser" -p"$targetDBPass" "$targetDBName" < "$dumpFile"
  if [ $? -ne 0 ]; then
    echo "$(date +'%Y-%m-%d %H:%M:%S') [ERROR] Failed to import data into target database: ${targetDBName}" | tee -a "$logFile"
    return 3
  fi

  if [ -f "$dumpFile" ]; then
    gzip "$dumpFile"
  fi

  echo "$(date +'%Y-%m-%d %H:%M:%S') [INFO] Database synchronization completed successfully: '${sourceDBHost}:${sourceDBName}' -> '${targetDBHost}:${targetDBName}'" | tee -a "$logFile"
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
    echo "$(date +'%Y-%m-%d %H:%M:%S') [ERROR] Database backup parameters cannot be empty." | tee -a "$logFile"
    return 1
  fi

  local backupFile="$syncDir/targeBackup_${targetDBName}_$(date +%Y%m%d%H%M%S).sql"

  # Clean expired backup files
  #find "$syncDir" -mtime +"$backupKeeptime" -type f -name "targeBackup_${targetDBName}_*.sql" -exec ls {} \;
  find "$syncDir" -mtime +"$backupKeeptime" -type f -name "targeBackup_${targetDBName}_*.sql" -exec rm -f {} \;

  # Backup database
  mysqldump -h"$targetDBHost" -P"$targetDBPort" -u"$targetDBUser" -p"$targetDBPass" "$targetDBName" > "$backupFile"

  if [ $? -ne 0 ]; then
    echo "$(date +'%Y-%m-%d %H:%M:%S') [ERROR] Failed to back up database: ${targetDBName}" | tee -a "$logFile"
    return 2
  fi

  if [ -f "$backupFile" ]; then
    gzip "$backupFile"
  fi
  echo "$(date +'%Y-%m-%d %H:%M:%S') [INFO] Database backup completed successfully: ${backupFile}.gz" | tee -a "$logFile"
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
        echo "$(date +'%Y-%m-%d %H:%M:%S') [INFO] $service is not running on $host" | tee -a "$logFile"
        return 0
    fi

    echo "$(date +'%Y-%m-%d %H:%M:%S') [INFO] Stopping $service on $host..." | tee -a "$logFile"

    if ! remoteExec "$host" "$user" "sudo systemctl stop $service"; then
        echo "$(date +'%Y-%m-%d %H:%M:%S') [ERROR] Failed to stop $service on $host" | tee -a "$logFile"
        return 1
    fi

    for ((i=0; i<30; i++)); do
        if ! remoteExec "$host" "$user" "systemctl is-active --quiet $service"; then
            echo "$(date +'%Y-%m-%d %H:%M:%S') [INFO] $service stopped successfully on $host" | tee -a "$logFile"
            return 0
        fi
        sleep 1
    done

    echo "$(date +'%Y-%m-%d %H:%M:%S') [ERROR] Timeout waiting for $service to stop on $host" | tee -a "$logFile"
    return 2
}

startService() {
    local host=$1
    local user=$2
    local service=$3

    if remoteExec "$host" "$user" "systemctl is-active --quiet $service"; then
        echo "$(date +'%Y-%m-%d %H:%M:%S') [INFO] $service is already running on $host" | tee -a "$logFile"
        return 0
    fi

    echo "$(date +'%Y-%m-%d %H:%M:%S') [INFO] Starting $service on $host..." | tee -a "$logFile"

    if ! remoteExec "$host" "$user" "sudo systemctl start $service"; then
        echo "$(date +'%Y-%m-%d %H:%M:%S') [ERROR] Failed to start $service on $host" | tee -a "$logFile"
        return 1
    fi

    for ((i=0; i<30; i++)); do
        if remoteExec "$host" "$user" "systemctl is-active --quiet $service"; then
            echo "$(date +'%Y-%m-%d %H:%M:%S') [INFO] $service started successfully on $host" | tee -a "$logFile"
            return 0
        fi
        sleep 1
    done

    echo "$(date +'%Y-%m-%d %H:%M:%S') [ERROR] Timeout waiting for $service to start on $host" | tee -a "$logFile"
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

msg2ComCat() {
  local tigaseEmployeeID="$1"
  local logMessage="$2"

  encodeMessage=$(urlencode "$logMessage")
  tigaseMessageBody="$encodeMessage"
  curlData="appId=$tigaseAppID&password=$tigaseAppPassword&employee_id=$tigaseEmployeeID&body=$tigaseMessageBody"
  curl -X POST -d "$curlData" "$tigaseApiURL" &> /dev/null
}

backupKeycloakDB() {
  targeKeycloakVars=$(ssh "$syncTargeHost" cat "$syncTargeConf" | getDBConf)

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
  sourceKeycloakVars=$(ssh "$syncSourceHost" cat "$syncSourceConf" | getDBConf)
  targeKeycloakVars=$(ssh "$syncTargeHost" cat "$syncTargeConf" | getDBConf)

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

  stopKeycloak "$targetKeycloakHosts"
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

  startKeycloak "$targetKeycloakHosts"
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
  msg2ComCat "$tigaseEmployeeID" "$logMessage"
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

checkKeycloakStatus() {
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

checkKeycloakReady() {
    local serviceHost="$1"
    local keycloakUrl="https://${serviceHost}:9000/health/ready"

    local result
    local overall
    local warnings
    local logMessage

    result=$(curl -k -s --connect-timeout 10 --max-time 30 "$keycloakUrl")
    local ret=$?

    if [[ $ret -ne 0 ]]; then
        logMessage="Keycloak Health Check Failed"$'\n'"Host: ${serviceHost}"$'\n'"URL: ${keycloakUrl}"$'\n'"Reason: Unable to connect"

        msg2ComCat "$tigaseEmployeeID" "$logMessage"
        return 1
    fi

    if ! echo "$result" | jq -e . >/dev/null 2>&1; then
        logMessage="Keycloak Health Check Failed"$'\n'"Host: ${serviceHost}"$'\n'"URL: ${keycloakUrl}"$'\n'"Reason: Invalid JSON response"

        msg2ComCat "$tigaseEmployeeID" "$logMessage"
        return 1
    fi

    overall=$(echo "$result" | jq -r '.status')

    warnings=$(echo "$result" | jq -r '
        (.checks // [])
        | .[]
        | select(.status != "UP")
        | "\(.name): \(.status)"
    ')

    if [[ "$overall" != "UP" ]]; then
        logMessage="Keycloak Health Check Failed"$'\n'"Host: ${serviceHost}"$'\n'"URL: ${keycloakUrl}"$'\n'"Overall Status: ${overall}"$'\n'"Failed Checks:"$'\n'"${warnings}"$'\n'"Action Required: Verify Keycloak service and network connectivity."

        msg2ComCat "$tigaseEmployeeID" "$logMessage"
        return 1
    fi

    return 0
}

getToken() {
  userToken=$(curl -sk \
  -X POST "$keycloakUrl/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=$keycloakAdmin" \
  -d "password=$keycloakPassword" \
  -d "grant_type=password" \
  -d "client_id=admin-cli" | jq -r '.access_token')
  echo "$userToken"
}

setCredentials() {
  kcadm.sh config credentials --server "$keycloakUrl" --realm master --user "$keycloakAdmin" --password "$keycloakPassword" >/dev/null 2>&1
}

execDBSql() {
  local sourceKeycloakVars=$(ssh "$syncSourceHost" cat "$syncSourceConf" | getDBConf)

  local dbType=$(echo "$sourceKeycloakVars" | grep "^dbType" | awk -F':' '{print $2}')
  local dbUser=$(echo "$sourceKeycloakVars" | grep "^dbUser" | awk -F':' '{print $2}')
  local dbPass=$(echo "$sourceKeycloakVars" | grep "^dbPass" | awk -F':' '{print $2}')
  local dbHost=$(echo "$sourceKeycloakVars" | grep "^dbHost" | awk -F':' '{print $2}')
  local dbPort=$(echo "$sourceKeycloakVars" | grep "^dbPort" | awk -F':' '{print $2}')
  local dbName=$(echo "$sourceKeycloakVars" | grep "^dbName" | awk -F':' '{print $2}')

  local execSql="$1"
  mysql -h "$dbHost" -P "${dbPort:-3306}" -u "$dbUser" -p"$dbPass" -D "$dbName" -e "$execSql" 2>/dev/null
}

getRealmsName() {
  execDBSql "select NAME from REALM \G;"  | grep ^NAME: | awk '{print $2}'
}

getRealmsID() {
  local realmsID="$1"
  execDBSql "select ID from REALM where NAME='"$realmsID"' \G;"  | grep ^ID: | awk '{print $2}'
}

getRealmsProviderID() {
  local realmsName="$1"
  local realmsID=$(getRealmsID "$realmsName")
  execDBSql "select ID from COMPONENT where PROVIDER_TYPE = 'org.keycloak.storage.UserStorageProvider' and REALM_ID = '"$realmsID"' \G;" | grep ^ID: | awk '{print $2}'
}

getProviderName() {
  local providerID="$1"
  execDBSql "select NAME from COMPONENT where PROVIDER_TYPE = 'org.keycloak.storage.UserStorageProvider' and ID = '"$providerID"' \G;" | grep ^NAME: | awk '{print $2}'
}

getProviderLdapConf() {
  local providerID="$1"
  execDBSql "select name,value from COMPONENT_CONFIG where (name='connectionUrl' or name='bindDn' or name='bindCredential') and COMPONENT_ID='${providerID}' \G;" \
  	    | awk '{val=$0} /name:/ {sub(/^[^:]+:[[:space:]]*/, "", val); n=val} /value:/ {sub(/^[^:]+:[[:space:]]*/, "", val); print n ": " val}'
}

checkLdap() {
  local realmName="$1"
  local ldapUrl="$2"
  local ldapBindDn="$3"
  local ldapBindCredential="$4"
  local userToken=$(getToken)

  if [[ -z "${realmName}" || -z "${ldapUrl}" || -z "${ldapBindDn}" || -z "${ldapBindCredential}" ]]; then
    echo "Usage: $0 ldap check <realm name> <ldap url> <ldap bindn> <ldap bind credential>"
    return 1
  fi

  local httpResponse=$(curl -s -w "\n%{http_code}" -X POST \
  "$keycloakUrl/admin/realms/$realmName/testLDAPConnection" \
  -H "Authorization: Bearer $userToken" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "action=testAuthentication" \
  --data-urlencode "connectionUrl=$ldapUrl" \
  --data-urlencode "bindDn=$ldapBindDn" \
  --data-urlencode "bindCredential=$ldapBindCredential" \
  --data-urlencode "useTruststoreSpi=ldapsOnly")

  local httpCode=$(echo "$httpResponse" | tail -n1)
  if [ "$httpCode" -eq 200 ] || [ "$httpCode" -eq 204 ]; then
    return 0
  else
    return 1
  fi
}

checkProviderLdap() {
  totalStatus=0
  for realmName in $(getRealmsName); do
    for providerID in $(getRealmsProviderID "$realmName"); do
      local ldapConf=$(getProviderLdapConf "$providerID")
      local ldapUrl=$(echo "$ldapConf" | grep "connectionUrl:" | awk '{print $2}')
      local ldapBindDn=$(echo "$ldapConf" | grep "bindDn:" | awk '{print $2}')
      local ldapBindCredential=$(echo "$ldapConf" | grep "bindCredential:" | awk '{print $2}')
      local providerName=$(getProviderName "$providerID")

      checkLdap "$realmName" "$ldapUrl" "$ldapBindDn" "$ldapBindCredential"
      local ret=$?
      if [ $ret -ne 0 ]; then
        totalStatus=$((totalStatus + 1))
        echo "$(date +%Y-%m-%d-%H:%M:%S) [ERROR] Test failure $realmName -> $providerName." | tee -a "$logFile"
      else
        echo "$(date +%Y-%m-%d-%H:%M:%S) [INFO] Test passed $realmName -> $providerName."
      fi
      #break 2
    done
  done
  if [ "$totalStatus" -eq 0 ]; then
    exit 0
  fi
  logMessage="Websso provider Failed:"$'\n'"please check log file $logFile on $(hostname -s)"
  msg2ComCat "$tigaseEmployeeID" "$logMessage"
}

case "$parameter1" in
  keycloak)
    case "$parameter2" in
      stop)
	case "$parameter3" in
          target)
            stopKeycloak "$targetKeycloakHosts"
            ;;
          source)
            stopKeycloak "$sourceKeycloakHosts"
            ;;
          *)
            echo "Examples:"
            echo "  $0 keycloak stop target"
            echo "  $0 keycloak stop source"
            ;;
        esac
        ;;
      start)
	case "$parameter3" in
          target)
            startKeycloak "$targetKeycloakHosts"
            ;;
          source)
            startKeycloak "$sourceKeycloakHosts"
            ;;
          *)
            echo "Examples:"
            echo "  $0 keycloak start target"
            echo "  $0 keycloak start source"
            ;;
        esac
        ;;
      restart)
	case "$parameter3" in
          target)
            stopKeycloak "$targetKeycloakHosts"
            startKeycloak "$targetKeycloakHosts"
            ;;
          source)
            stopKeycloak "$sourceKeycloakHosts"
            startKeycloak "$sourceKeycloakHosts"
            ;;
          *)
            echo "Examples:"
            echo "  $0 keycloak restart target"
            echo "  $0 keycloak restart source"
            ;;
        esac
        ;;
      status)
	keycloakHosts="${sourceKeycloakHosts} ${targetKeycloakHosts}"
        checkKeycloakStatus "$keycloakHosts"
        ;;
      check)
	keycloakHosts="${sourceKeycloakHosts} ${targetKeycloakHosts}"
	for keycloakHost in $keycloakHosts; do
	  checkKeycloakReady "$keycloakHost"
          ret=$?
	  if [ "$ret" -ne 0 ]; then
            echo "$(date +%Y-%m-%d-%H:%M:%S) [ERROR] Node $keycloakHost check failed."
	  else
            echo "$(date +%Y-%m-%d-%H:%M:%S) [INFO] Node $keycloakHost check passed successfully."
          fi
        done
	;;
      *)
	echo "Usage: $0 keycloak {stop|start|restart|status|check} [source|target]"
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
    ldap)
      case "$parameter2" in
        check)
	     checkLdap
             ;;
        scan)
	     checkProviderLdap
             ;;
        disable)
             echo disable
             ;;
        enable)
             echo enable
             ;;
        *)
             echo "Usage: $0 ldap {check|scan|disable|enable}"
             ;;
        esac
        ;;
    *)
      echo "Usage: $0 {keycloak|db|ldap}"
      ;;
esac
exit 0
