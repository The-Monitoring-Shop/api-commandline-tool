#!/usr/bin/env bash

################################################################################
# Bulk updates health rules on congtroller
#
# NB;
#     Various HR types have varying patterns of 'field' names
#     HR String (-H) is used in a 'contains' match
#     Patterns (-X, -Y) are regex, be sure to escape as required
#
# WARNING;
#     Not adding a -H flag will pull ALL HRs !!!
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
            -Y [pattern]   Pattern to match in health rule output
            -Z [pattern]   Value to change pattern to

        Examples;
            ./update_healthrule_bulk.sh -E prod -A 123 -H "CPU Utilisation" -X "\"evaluateToTrueOnNoData\":false" -Y "\"evaluateToTrueOnNoData\":true"
            ./update_healthrule_bulk.sh -E prod -A 123 -X "\"evaluateToTrueOnNoData\":false" -Y "\"evaluateToTrueOnNoData\":true"
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
    PATTERNIN="${OPTARG}"
    ;;
  Z)
    PATTERNOUT="${OPTARG}"
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

# Override params
# ENVIRONMENT=""
# APPID=""
# HRSTRING=""
# PATTERNIN=""
# PATTERNOUT=""

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
  # If we didnt get an HREXACT, we cant continue
  if [[ -z ${HREXACT} ]]; then
    echo "No -X param passed, defaulting to true"
    HREXACT=true
  fi
  # If we didnt get any PATTERNs, we cant continue
  if [[ -z ${PATTERNIN} || -z ${PATTERNOUT} ]]; then
    echo "No -Y or -Z param passed."
    usage
    exit 1
  fi
}

# Clear down node related info
resetVars() {
  HROUTPUT=""
  HROUTPUTCHECK=""
  HROUTPUTUPDATED=""
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
  echo "Getting list of health rule IDs;"
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

# Update each health rule
updateHRData() {
  echo "Starting HR updates"

  # Reset our vars and carry on
  resetVars

  OLDIFS=$IFS
  IFS=$'\r\n'

  #  Iterate through HR list
  for HRITEM in $HRLIST; do
    HRID=$(echo ${HRITEM} | cut -d "," -f1)
    echo "Updating ${HRID}..."
    echo "Changing '${PATTERNIN}' to '${PATTERNOUT}'..."
    # GET our HR json
    HROUTPUT=$(../act.sh -E ${ENVIRONMENT} controller call -X GET ${HEATHRULEURI}/${HRID})
    # echo "HROUTPUT: ${HROUTPUT}"

    # Do we see the PATTERNIN in our HR?
    HROUTPUTCHECK=$(echo ${HROUTPUT} | grep -E "${PATTERNIN}")
    # echo "HROUTPUTCHECK: ${HROUTPUTCHECK}"
    if [[ -z ${HROUTPUTCHECK} ]]; then
      echo "         No pattern match found in health rule, skipping any changes..."
      continue
    else
      # Update the HR json
      HROUTPUTUPDATED=$(echo "${HROUTPUT}" | sed -r "s|${PATTERNIN}|${PATTERNOUT}|g")
      # echo "HROUTPUTUPDATED: ${HROUTPUTUPDATED}"
      # PUT our HR json back
      HRPUTRESPONSE=$(../act.sh -E ${ENVIRONMENT} controller call -X PUT -d "${HROUTPUTUPDATED}" ${HEATHRULEURI}/${HRID})
      # echo "HRPUTRESPONSE: ${HRPUTRESPONSE}"
      HRPUTRESPONSECHECK=$(echo ${HRPUTRESPONSE} | grep -E "\"id\":${HRID},")
      # echo "HRPUTRESPONSECHECK: ${HRPUTRESPONSECHECK}"
      if [[ ${HRPUTRESPONSECHECK} ]]; then
        echo "         Updated"
      else
        echo "         Error"
      fi
    fi
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
