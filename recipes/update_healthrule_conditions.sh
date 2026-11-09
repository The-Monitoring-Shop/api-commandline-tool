#!/usr/bin/env bash

################################################################################
# Duplicate health rules in an application with a suffix
#
# NB;
#     HR String (-H) is used in either an exact or contains match, based on (-X) value
#     Argument (-Z) is a string value
#
################################################################################

usage() {
  echo "
        Usage:
            $0 [params]

        Params;
            -E [string]    The ACT environment name (Mandatory)
            -A [number]    Application ID you want to run for
            -H [string]    String for health rule matching
            -X [boolean]   Exact match or contains (default is exact, true)
            -Y [string]    String to use for JQ mapping update to critical conditions (use single quotes)
                            i.e. remove shortName C & D - 'map(select(.shortName != "C") | select(.shortName != "D"))'
            -Z [string]    String to use for JQ mapping update to warning conditions (use single quotes)
                            If left blank will use -Y value

        Examples;
            ./update_healthrule_conditions.sh -E prod -A 123 -H "CPU Utilisation" -Y 'map(select(.shortName != "C") | select(.shortName != "D"))'
            ./update_healthrule_conditions.sh -E prod -A 123 -H "^.* Utilisation$" -X false -Y 'map(select(.shortName != "C") | select(.shortName != "D"))'
  "
}

################################################################################
# Setup Variables, etc
################################################################################

# Read input params
while getopts ":E:A:H:X:Y:Z:" opt "$@"; do
  case "${opt}" in
  E)
    ENVIRONMENT="${OPTARG}"
    ;;
  A)
    APPID="${OPTARG}"
    ;;
  H)
    HRSTRING="${OPTARG}"
    ;;
  X)
    HREXACT="${OPTARG}"
    ;;
  Y)
    JQSTRINGCRIT="${OPTARG}"
    ;;
  Z)
    JQSTRINGWARN="${OPTARG}"
    ;;
  :)
    usage
    exit 1
    ;;
  *)
    echo "Invalid flag ${OPTARG}, exiting..."
    exit 1
    ;;
  esac
done

################################################################################
# Start of functions
################################################################################

# Checks
runChecks() {
  # If we didnt get an ENVIRONMENT, we cant continue
  if [[ -z ${ENVIRONMENT} ]]; then
    echo "No -E param passed."
    usage
    exit 1
  fi
  # If we didnt get an APPID, we cant continue
  if [[ -z ${APPID} ]]; then
    echo "No -A param passed."
    usage
    exit 1
  fi
  # If we didnt get an HRSTRING, we cant continue
  if [[ -z ${HRSTRING} ]]; then
    echo "No -H param passed."
    usage
    exit 1
  fi
  # If we didnt get an HRSTRING, we cant continue
  if [[ -z ${HREXACT} ]]; then
    echo "No -X param passed, defaulting to true"
    HREXACT=true
  fi
  # If we didnt get an JQSTRINGCRIT, we cant continue
  if [[ -z ${JQSTRINGCRIT} ]]; then
    echo "No -Y param passed."
    usage
    exit 1
  elif [[ -z ${JQSTRINGWARN} ]]; then
    echo "No -Z param passed, using -Y value."
    JQSTRINGWARN=${JQSTRINGCRIT}
  fi
}

# Clear down node related info
resetVars() {
  HRID=""
  HRNAME=""
  HROUTPUT=""
  NEWHR=""
  HRPUTRESPONSE=""
  HRPUTRESPONSECHECK=""
}

################################################################################
# GetData functions
################################################################################

# Get health rule data
getHRLIST() {
  # Perform a Login to get tokens
  echo "----------------------------------------------------------------------------"
  echo "Performing login to controller in environment: ${ENVIRONMENT}"
  LOGINRESPONSE=$(../act.sh -E ${ENVIRONMENT} controller call -X GET /controller/auth?action=login)
  echo "  ${LOGINRESPONSE}"

  echo "----------------------------------------------------------------------------"
  echo "Getting matching HRs"
  # Set our URI for getting HRs
  HEATHRULEURI="/controller/alerting/rest/v1/applications/${APPID}/health-rules"
  # Get list of HR IDs matching HRSTRING
  if [[ ${HREXACT} == "true" ]]; then
    echo "  -H '${HRSTRING}', getting exact matching HR"
    HRLIST=$(../act.sh -E ${ENVIRONMENT} controller call -X GET ${HEATHRULEURI} | jq -r --arg PATTERN "${HRSTRING}" '.[] | select(.name == $PATTERN) | "\(.id),\(.name)"')
  else
    echo "  -H '${HRSTRING}', getting regex matching HRs"
    HRLIST=$(../act.sh -E ${ENVIRONMENT} controller call -X GET ${HEATHRULEURI} | jq -r --arg PATTERN "${HRSTRING}" '.[] | select(.name | match($PATTERN)) | "\(.id),\(.name)"')
  fi
  echo "${HRLIST}"
  echo "----------------------------------------------------------------------------"
}

# Duplucate each health rule
updateHRData() {
  echo "Starting HR duplications"

  # Reset our vars and carry on
  resetVars

  OLDIFS=$IFS
  IFS=$'\r\n'

  #  Iterate through HR list
  for HRITEM in $HRLIST; do
    HRID=$(echo ${HRITEM} | cut -d "," -f1)
    HRNAME=$(echo ${HRITEM} | cut -d "," -f2)
    echo "Updating ${HRID}, '${HRNAME}'..."
    echo "----------------------------------------------------------------------------"

    # GET our HR json
    HROUTPUT=$(../act.sh -E ${ENVIRONMENT} controller call -X GET ${HEATHRULEURI}/${HRID})
    # echo "HROUTPUT: ${HROUTPUT}..."
    echo "----------------------------------------------------------------------------"

    # Update our JQSTRINGs with de-dupe logic on shortName
    JQSTRINGCRIT="${JQSTRINGCRIT} | group_by(.shortName) | map(.[0])"
    JQSTRINGWARN="${JQSTRINGWARN} | group_by(.shortName) | map(.[0])"

    # Update HROUTPUT
    NEWHR=$(echo "$HROUTPUT" | jq '
      # 1. Update Critical Criteria
      .evalCriterias.criticalCriteria as $critical |
      (
        $critical.conditions | 
        '$JQSTRINGCRIT'
        # map(select(.evalDetail.metricPath != "Errors per Minute") | select(.shortName != "E"))
        # map(select(.evalDetail.metricPath != "Average Response Time (ms)") | select(.shortName != "B"))

      ) as $new_critical_conditions |
      (
        # Update the conditions array
        .evalCriterias.criticalCriteria.conditions = $new_critical_conditions |
        # Update the conditionExpression string: join the shortNames
        .evalCriterias.criticalCriteria.conditionExpression = ($new_critical_conditions | map(.shortName) | join(" AND "))
      )

      # 2. Update Warning Criteria
      | .evalCriterias.warningCriteria as $warning |
      (
        $warning.conditions | 
        '$JQSTRINGWARN'
        # map(select(.evalDetail.metricPath != "Errors per Minute") | select(.shortName != "E"))
        # map(select(.evalDetail.metricPath != "Average Response Time (ms)") | select(.shortName != "B"))

      ) as $new_warning_conditions |
      (
        # Update the conditions array
        .evalCriterias.warningCriteria.conditions = $new_warning_conditions |
        # Update the conditionExpression string: join the shortNames
        .evalCriterias.warningCriteria.conditionExpression = ($new_warning_conditions | map(.shortName) | join(" AND "))
      )
    ')
    # echo "NEWHR: ${NEWHR}"

    # Update our HR JSON
    HRPUTRESPONSE=$(../act.sh -E ${ENVIRONMENT} controller call -X PUT -d "${NEWHR}" ${HEATHRULEURI}/${HRID})
    # echo "HRPUTRESPONSE: ${HRPUTRESPONSE}..."
        
    HRPUTRESPONSECHECK=$(echo ${HRPUTRESPONSE} | grep -E "\"name\":\"${HRNAME}\",")
    if [[ ${HRPUTRESPONSECHECK} ]]; then
      echo "" 
      echo "Health Rule Update - Success"
    else
      echo "" 
      echo "Health Rule Update - Failed"
    fi
    echo "----------------------------------------------------------------------------"
  done

  IFS=$OLDIFS

  echo "----------------------------------------------------------------------------"
  echo "Completed HR updates"
  echo "----------------------------------------------------------------------------"
}


################################################################################
################################################################################
# MAIN CODE
################################################################################
################################################################################

# Lets get ready
runChecks

# Lets go
getHRLIST
updateHRData
