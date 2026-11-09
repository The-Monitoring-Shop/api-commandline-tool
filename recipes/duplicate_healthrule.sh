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
            -Z [pattern]   Suffix string

        Examples;
            ./duplicate_healthrule.sh -E prod -A 123 -H "CPU Utilisation" -Z "COPY"
            ./duplicate_healthrule.sh -E prod -A 123 -H "^.* Utilisation" -X false -Z "COPY"
  "
}

################################################################################
# Setup Variables, etc
################################################################################

# Read input params
while getopts ":E:A:H:X:Z:" opt "$@"; do
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
  Z)
    SUFFIX="${OPTARG}"
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
  # If we didnt get a SUFFIX, we cant continue
  if [[ -z ${SUFFIX} ]]; then
    echo "No -Z param passed."
    usage
    exit 1
  fi
}

# Clear down node related info
resetVars() {
  HRID=""
  HRNAME=""
  HROUTPUT=""
  NEWHRNAME=""
  HROUTPUTUPDATED=""
  NEWHR=""
  HRPOSTRESPONSE=""
  HRPOSTRESPONSECHECK=""
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
duplicateHRData() {
  echo "Starting HR duplications"

  # Reset our vars and carry on
  resetVars

  OLDIFS=$IFS
  IFS=$'\r\n'

  #  Iterate through HR list
  for HRITEM in $HRLIST; do
    HRID=$(echo ${HRITEM} | cut -d "," -f1)
    HRNAME=$(echo ${HRITEM} | cut -d "," -f2)
    NEWHRNAME="${HRNAME} ${SUFFIX}"
    echo "Duplicating ${HRID}, '${HRNAME}' to '${NEWHRNAME}'"
    echo "----------------------------------------------------------------------------"

    # GET our HR json
    HROUTPUT=$(../act.sh -E ${ENVIRONMENT} controller call -X GET ${HEATHRULEURI}/${HRID})
    # echo "HROUTPUT: ${HROUTPUT}..."

    # Update the name in our HR JSON
    HROUTPUTUPDATED=$(echo "${HROUTPUT}" | sed -r -e "s|\"name\":\"${HRNAME}\",|\"name\":\"${NEWHRNAME}\",|")
    # echo "HROUTPUTUPDATED: ${HROUTPUTUPDATED}..."

    # De-duple shortNames
    NEWHR=$(echo "$HROUTPUTUPDATED" | jq '
      # Deduplicate Critical Criteria
      .evalCriterias.criticalCriteria.conditions |= (
        # Group all conditions by the value of their shortName
        group_by(.shortName) | 
        # Keep only the first element (the representative) of each group
        map(.[0])
      ) |
      
      # Deduplicate Warning Criteria
      .evalCriterias.warningCriteria.conditions |= (
        # Group all conditions by the value of their shortName
        group_by(.shortName) | 
        # Keep only the first element (the representative) of each group
        map(.[0])
      )
    ')
    # echo "NEWHR: ${NEWHR}"

    # Import our renamed and de-duped HR JSON
    HRPOSTRESPONSE=$(../act.sh -E ${ENVIRONMENT} controller call -X POST -d "${NEWHR}" ${HEATHRULEURI})
    # echo "HRPOSTRESPONSE: ${HRPOSTRESPONSE}..."
    HRPOSTRESPONSECHECK=$(echo ${HRPOSTRESPONSE} | grep -E "\"name\":\"${NEWHRNAME}\",")
    if [[ ${HRPOSTRESPONSECHECK} ]]; then
      echo "" 
      echo "Health Rule Duplication - Success"
    else
      echo "" 
      echo "Health Rule Duplication - Failed"
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
duplicateHRData
