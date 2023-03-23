#!groovy

stage('SonarQube Code Quality Status') {
    when {
        expression {
            return params.SONAR
        }
    }
    steps {
        timestamps {
                script {
                    try{
                        def sonar_api_token='<replace_with_api_token>';
                        def sonar_project='<replace_with_project_name>';
                        sh """#!/bin/bash +x
                        echo "Checking status of SonarQube Project = ${sonar_project}"
                        sonar_status=`curl -s -u ${sonar_api_token}: <sonar_url>/api/qualitygates/project_status?projectKey=${sonar_project} | grep '{' | python -c 'import json,sys;obj=json.load(sys.stdin);print obj["'projectStatus'"]["'status'"];'`
                        echo "SonarQube status = \$sonar_status"
                        
                        case \$sonar_status in
                            "ERROR")
                                echo "Quality Gate Failed - Major Issues > 0"
                                echo "Check the SonarQube Project ${sonar_project} for further details."
                                exit 1
                            ;;
                            "OK")
                                echo "Quality Gate Passed"
                                echo "Check the SonarQube Project ${sonar_project} for further details."
                                exit 0
                            ;;
                        esac
                        
                        """
                    
                    echo 'Code Quality Checks Complete.'
                    //mark the pipeline as unstable and continue
                }catch(e){
                    currentBuild.result = 'UNSTABLE'
                    result = "FAIL"
                }
            }
        }
    }
}
