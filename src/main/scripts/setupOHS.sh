#!/bin/bash

#Function to output message to StdErr
function echo_stderr ()
{
    echo "$@" >&2
}

#Function to display usage message
function usage()
{
    echo_stderr "./setupOHS.sh <ohs domain name> <ohs component name> <ohsSSLKeystoreData> <ohsSSLKeystorePassword> <oracle vault password> <keyType>"
}

# Cleaning all installer files 
function cleanup()
{
    echo "Cleaning up temporary files..."
    rm -f $BASE_DIR/setupOHS.sh
    echo "Cleanup completed."
}

# Verifies whether user inputs are available
function validateInput()
{
    if [ -z "$OHS_DOMAIN_NAME" ]
    then
       echo_stderr "OHS domain name is required. "
       exit 1
    fi	
    
    if [ -z "$OHS_COMPONENT_NAME" ]
    then
       echo_stderr "OHS domain name is required. "
       exit 1
    fi	
    
    
    if [ -z "${OHS_KEY_STORE_DATA}" ] || [ -z "${OHS_KEY_STORE_PASSPHRASE}" ]
    then
       echo_stderr "One of the required values for enabling Custom SSL (ohsKeyStoreData,ohsKeyStorePassPhrase) is not provided"
       exit 1
    fi
    
    if [ -z "$ORACLE_VAULT_PASSWORD" ]
    then
       echo_stderr "Oracle vault password is required to add custom ssl to OHS server"
       exit 1
    fi
    
    if [ -z "$OHS_KEY_TYPE" ] 
    then
       echo_stderr "Provide KeyType either JKS or PKCS12"
       exit 1
    fi    
}

#Check whether service is started
function verifyService()
{
    serviceName=$1
    sudo systemctl status $serviceName | grep "active"     
    if [[ $? != 0 ]]; 
    then
        echo "$serviceName is not in active state"
        exit 1
    fi
    echo $serviceName is active and running
}


#Restatr the ohs component service
function restrtComponent()
{
	echo "Re-starting ohs component service"
	attempt=1
	while [[ $attempt -lt 6 ]]
	do
		echo "Re-starting ohs component service attempt $attempt"
		sudo systemctl restart ohs_component
		sleep 1m
		attempt=`expr $attempt + 1`
		sudo systemctl status ohs_component | grep active
		if [[ $? == 0 ]];
		then
			echo "ohs_component service started successfully"
			break
		fi
		sleep 3m
	done
}


# Oracle Vault needs to be created to add JKS keystore or PKCS12 certificate for OHS
function createOracleVault()
{
    runuser -l oracle -c "mkdir -p ${OHS_VAULT_PATH}"
    runuser -l oracle -c  "${INSTALL_PATH}/oracle/middleware/oracle_home/oracle_common/bin/orapki wallet create -wallet ${OHS_VAULT_PATH} -pwd ${ORACLE_VAULT_PASSWORD} -auto_login"
    if [[ $? == 0 ]]; 
    then
        echo "Successfully oracle vault is created"
    else
        echo_stderr "Failed to create oracle vault"
        exit 1
    fi	
    ls -lt ${OHS_VAULT_PATH}
}

# cleanup Oracle Vault with old certificates
function cleanupOracleVault()
{
	runuser -l oracle -c "rm  -rf ${OHS_VAULT_PATH}"
}

# Add provided certificates to Oracle vault created
function addCertficateToOracleVault()
{
    ohsKeyStoreData=$(echo "$OHS_KEY_STORE_DATA" | base64 --decode)
    ohsKeyStorePassPhrase=$(echo "$OHS_KEY_STORE_PASSPHRASE" | base64 --decode)

    case "${OHS_KEY_TYPE}" in
      "JKS")
          echo "$ohsKeyStoreData" | base64 --decode > ${OHS_VAULT_PATH}/ohsKeystore.jks
          sudo chown -R $username:$groupname ${OHS_VAULT_PATH}/ohsKeystore.jks
          # Validate JKS file
          KEY_TYPE=`keytool -list -v -keystore ${OHS_VAULT_PATH}/ohsKeystore.jks -storepass ${ohsKeyStorePassPhrase} | grep 'Keystore type:'`
          if [[ $KEY_TYPE == *"jks"* ]]; then
              runuser -l oracle -c  "${INSTALL_PATH}/oracle/middleware/oracle_home/oracle_common/bin/orapki wallet  jks_to_pkcs12  -wallet ${OHS_VAULT_PATH}  -pwd ${ORACLE_VAULT_PASSWORD} -keystore ${OHS_VAULT_PATH}/ohsKeystore.jks -jkspwd ${ohsKeyStorePassPhrase}"
              if [[ $? == 0 ]]; then
                 echo "Successfully added JKS keystore to Oracle Wallet"
              else
                 echo_stderr "Adding JKS keystore to Oracle Wallet failed"
                 exit 1
              fi
          else
              echo_stderr "Not a valid JKS keystore file"
              exit 1
          fi
          ;;
  	
     "PKCS12")  	
          echo "$ohsKeyStoreData" | base64 --decode > ${OHS_VAULT_PATH}/ohsCert.p12
          sudo chown -R $username:$groupname ${OHS_VAULT_PATH}/ohsCert.p12
          runuser -l oracle -c "${INSTALL_PATH}/oracle/middleware/oracle_home/oracle_common/bin/orapki wallet import_pkcs12 -wallet ${OHS_VAULT_PATH} -pwd ${ORACLE_VAULT_PASSWORD} -pkcs12file ${OHS_VAULT_PATH}/ohsCert.p12  -pkcs12pwd ${ohsKeyStorePassPhrase}"
          if [[ $? == 0 ]]; then
              echo "Successfully added certificate to Oracle Wallet"
          else
              echo_stderr "Unable to add PKCS12 certificate to Oracle Wallet"
              exit 1
          fi
     	  ;;
  esac
}

# Backup the existing oracle vault
function backupOracleVault()
{
	runuser -l oracle -c "cp  -rf ${OHS_VAULT_PATH} ${OHS_VAULT_PATH}_backup"
}

#function renew certificates with supplied certificates
function renewCertificates()
{
	backupOracleVault
	cleanupOracleVault
	createOracleVault
	addCertficateToOracleVault
	restrtComponent
	sudo systemctl status "ohs_component" | grep "active" 
	if [[ $? != 0 ]]; 
    then
        echo "$serviceName is not in active state"
        echo "Rolling back existing oracle vault data"
        runuser -l oracle -c "mv ${OHS_VAULT_PATH}_backup ${OHS_VAULT_PATH}"
        restrtComponent
        verifyService "ohs_component"
    else
    	echo $serviceName is active and running
    	echo "Renewing certificates is successful"
    	runuser -l oracle -c "rm -rf ${OHS_VAULT_PATH}_backup"
    fi
}

# Execution starts here

CURR_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
export BASE_DIR="$(readlink -f ${CURR_DIR})"

export OHS_DOMAIN_NAME=$1
export OHS_COMPONENT_NAME=$2
export OHS_KEY_STORE_DATA=$3
export OHS_KEY_STORE_PASSPHRASE=$4 
export ORACLE_VAULT_PASSWORD=$5
export OHS_KEY_TYPE=$6
export OHS_PATH="/u01/app/ohs"
export DOMAIN_PATH="/u01/domains"
export INSTALL_PATH="$OHS_PATH/install"
export OHS_DOMAIN_PATH=${DOMAIN_PATH}/${OHS_DOMAIN_NAME}
export OHS_VAULT_PATH="${DOMAIN_PATH}/ohsvault"
export  groupname="oracle"
export  username="oracle"


validateInput
renewCertificates
cleanup
