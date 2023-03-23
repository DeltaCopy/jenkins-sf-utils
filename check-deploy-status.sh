#!/usr/bin/env bash

job_name=$1
jenkins_api_token=$2
jenkins_username=$3
sf_username=$4
sf_password=$5
sf_url=$6
jenkins_url=$7

if [ "$#" -ne 6 ]; then
    echo "Usage: check-deploy-status.sh [Jenkins-PR-JOB-Name] [Jenkins-API-Token] [Jenkins-Username] [SF-Username] [SF-Password] [SF-URL] [Jenkins-URL]"
    exit 1
else
    echo "+++++++++++++++++++++++++++++++++++++++++++++++"
    echo "Checking Salesforce deployment status."
    echo "+++++++++++++++++++++++++++++++++++++++++++++++"
fi

# Change the API version to latest if required
api_version="43.0"
sessionId=""
metadataUrl=""

# console colours
NORM="\033[0m"
RED="\033[1;31m"
YELLOW="\e[0;33m"
GREEN="\e[0;32m"
LBLUE="\033[1;34m"
GRAY="\033[1;30m"
UNDERLINE="\033[4m"
BOLD="\033[1m"


# Login to Salesforce via SOAP API
salesforceAuthenticate(){


	sf_password=`echo ${sf_password} | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g; s/'"'"'/\&#39;/g'`
    cat << EOF > .login.xml
    <soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:urn="urn:partner.soap.sforce.com">
        <soapenv:Body>
            <urn:login>
                <urn:username>${sf_username}</urn:username>
            <urn:password>${sf_password}</urn:password>
        </urn:login>
    </soapenv:Body>
    </soapenv:Envelope>
EOF

    soap_url="$sf_url/services/Soap/u/$api_version"

    logger "INFO" "SOAP URL = $soap_url"
    if [ ! -f ".login.xml" ];then
        logger "ERROR" "Failed to create login.xml SOAP Payload."
    fi

    response=`curl -s $soap_url -H "Content-Type:text/xml;charset=UTF-8" -H "SOAPAction:login" -d @.login.xml`

    rm -f '.login.xml'

    if [ ! -z "$response" ];then
        sessionId=`echo $response | grep -oPm1 "(?<=<sessionId>)[^<]+"`
        metadataUrl=`echo $response | grep -oPm1 "(?<=<metadataServerUrl>)[^<]+"`
        #logger "DEBUG" "Metadata URL = $metadataUrl"
        if [ ! -z $sessionId ] && [ ! -z $metadataUrl ] ;then
            echo "+++++++++++++++++++++++++++++++++++++++++++++++"
            logger "INFO" "Salesforce Authentication OK."
            echo "+++++++++++++++++++++++++++++++++++++++++++++++"
        else
            logger "ERROR" "Salesforce Authenticate failed."
        fi
    else
        logger "ERROR" "Failed to get valid response from SOAP URL - $soap_url"
    fi
}


# Extract deployment Id from a Jenkins build log

extractDeploymentId(){
    if [ ! -z "$last_build_number" ]; then
        ((last_build_number--))

        if [ $last_build_number -gt 0 ]; then

            logger "INFO" "Last build number = #$last_build_number"

            if [ -f "$job_name-$last_build_number-output.log" ]; then
                rm -f "$job_name-$last_build_number-output.log"
            fi
            # get the console output of the last build
            logger "INFO" "Fetching Console log from last build."
            curl -s --user $jenkins_username:$jenkins_api_token $jenkins_url/$job_name/$last_build_number/consoleFull > $job_name-$last_build_number-output.log

            if [ -f "$job_name-$last_build_number-output.log" ];then
                logger "INFO" "Console log fetched."
                logger "DEBUG" "Console log file = $job_name-$last_build_number-output.log"

                logger "INFO" "Extracting deployment ID"

                deployment_id=`cat "$job_name-$last_build_number-output.log" | grep -w "Request ID for the current deploy task" | awk {'print $11'}`

                rm -f "$job_name-$last_build_number-output.log"

            fi
        fi
    fi
}


# Call the Salesforce API to check deployment status give a valid Id
checkStatus(){
    if [ ! -z "$deployment_id" ]; then
        logger "INFO" "Last deployment ID = $deployment_id"
         # make request to checkDeployStatus()

        cat << EOF > .deploy_status.xml
            <soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:met="http://soap.sforce.com/2006/04/metadata">
            <soapenv:Header>
                <met:SessionHeader>
                    <met:sessionId>$sessionId</met:sessionId>
                </met:SessionHeader>
            </soapenv:Header>
            <soapenv:Body>
                <met:checkDeployStatus>
                    <met:asyncProcessId>$deployment_id</met:asyncProcessId>
                    <met:includeDetails>false</met:includeDetails>
                </met:checkDeployStatus>
            </soapenv:Body>
            </soapenv:Envelope>
EOF


        logger "INFO" "Sending request to fetch last deployment status."
        curl -s $metadataUrl -H "Content-Type:text/xml;charset=UTF-8" -H "SOAPAction:checkDeployStatus" -d @.deploy_status.xml > deploy.log

        # deploy status in
        #   <xsd:enumeration value="Pending"/>
        #   <xsd:enumeration value="InProgress"/>
        #   <xsd:enumeration value="Succeeded"/>
        #   <xsd:enumeration value="SucceededPartial"/>
        #   <xsd:enumeration value="Failed"/>
        #   <xsd:enumeration value="Canceling"/>
        #   <xsd:enumeration value="Canceled"/>

        if [ -f "deploy.log" ]; then
            rm -f ".deploy_status.xml"


            last_deploy_status=`cat "deploy.log" | grep -oPm1 "(?<=<status>)[^<]+"`

            if [ ! -z "$last_deploy_status" ];then

                err=0
                case "$last_deploy_status" in
                    "Pending")
                        logger "CRITICAL" "Last deployment status = Pending"
                        err=1
                    ;;
                    "InProgress")
                        logger "CRITICAL" "Last deployment status = $last_deploy_status"
                        err=1
                    ;;
                    "Succeeded")
                        logger "INFO" "Last deployment status = $last_deploy_status"
                    ;;
                    "SucceededPartial")
                        logger "INFO" "Last deployment status = $last_deploy_status"
                    ;;
                    "Failed")
                        logger "WARNING" "Last deployment status = $last_deploy_status"
                    ;;
                    "Canceling")
                        logger "INFO" "Last deployment status = $last_deploy_status"
                        err=1
                    ;;
                    "Canceled")
                        logger "INFO" "Last deployment status = $last_deploy_status"
                    ;;
                esac

                if [[ $err == 1 ]]; then
                    logger "ERROR" "Last deployment status = $last_deploy_status"
                    logger "ERROR" "Not continuing further with PR validation.. Aborting."
                    exit 1
                fi
            fi

            rm -f "deploy.log"
        fi

    else
        logger "WARNING" "Failed to extract last deployment ID."
    fi

}

# logging
logger(){
    case "$1" in
        "ERROR")
            echo -e "$(date '+%Y/%m/%d %H:%M:%S'):${RED} $1 > $2 ${NORM}"
        ;;
        "CRITICAL")
            echo -e "$(date '+%Y/%m/%d %H:%M:%S'):${RED} $1 > $2 ${NORM}"
        ;;
        "WARNING")
            echo -e "$(date '+%Y/%m/%d %H:%M:%S'):${YELLOW} $1 > $2 ${NORM}"
        ;;
        "INFO")
            echo -e "$(date '+%Y/%m/%d %H:%M:%S'): $1 > $2"
        ;;

        "DEBUG")
            echo -e "$(date '+%Y/%m/%d %H:%M:%S'): $1 > $2"
        ;;
        "INFO2")
            echo -e "$(date '+%Y/%m/%d %H:%M:%S'):${BOLD} INFO > $2 ${NORM}"
        ;;
        "SUCCESS")
            echo -e "$(date '+%Y/%m/%d %H:%M:%S'):${LBLUE} INFO > $2 ${NORM}"
        ;;
    esac
}

# get last build number from PR JOB

auth_status=`curl -s -o /dev/null -I --user $jenkins_username:$jenkins_api_token $jenkins_url -w "%{http_code}"`

if [[ $auth_status == 200 ]]; then
    logger "INFO" "Jenkins Authentication OK."
    echo "+++++++++++++++++++++++++++++++++++++++++++++++"


    #Salesforce SOAP login
    salesforceAuthenticate


    # check status from previous build in Jenkins



    last_build_number=`curl -s --user $jenkins_username:$jenkins_api_token $jenkins_url/$job_name/lastBuild/buildNumber`

    # 1
    logger "INFO" "Checking deployment status."
    extractDeploymentId $last_build_number
    checkStatus $deployment_id
    echo "+++++++++++++++++++++++++++++++++++++++++++++++"




else
    logger "ERROR" "Jenkins Authentication Failed."
fi
