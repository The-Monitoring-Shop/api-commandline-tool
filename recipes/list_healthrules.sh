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

        Examples;
            ./list_healthrules.sh -E prod -A 123 -H "CPU Utilisation"
            ./list_healthrules.sh -E prod -A 123 -H "^.* Utilisation" -X false
  "
}

################################################################################
# Setup Variables, etc
################################################################################

# Read input params
while getopts ":E:A:H:X:" opt "$@"; do
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
  # If we didnt get an HREXACT, we cant continue
  if [[ -z ${HREXACT} ]]; then
    echo "No -X param passed, defaulting to true"
    HREXACT=true
  fi
}

# Clear down node related info
resetVars() {
  HRID=""
  HRNAME=""
  HROUTPUT=""
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
outputHRData() {
  echo "Starting HR output"

  # Reset our vars and carry on
  resetVars

  OLDIFS=$IFS
  IFS=$'\r\n'

  #  Iterate through HR list
  for HRITEM in $HRLIST; do
    HRID=$(echo ${HRITEM} | cut -d "," -f1)
    HRNAME=$(echo ${HRITEM} | cut -d "," -f2)
    echo "Listing ${HRID}, '${HRNAME}'..."

    # GET our HR json
    HROUTPUT=$(../act.sh -E ${ENVIRONMENT} controller call -X GET ${HEATHRULEURI}/${HRID})
    # echo "HROUTPUT: ${HROUTPUT}..."

    # List HROUTPUT
    echo "$HROUTPUT" | jq '
      . as $parent |

      # Define a reusable filter to extract and format condition data from an array
      def extract_conditions:
        # 1. Group the conditions by their shortName
        group_by(.shortName) |
        # 2. Map over the groups and select the first element of each group
        map(.[0]) | 
        # 3. Apply the final formatting (using the single-string format from previous request)
        map(      
            "\(.shortName) - \(.evalDetail.metricEvalDetail.metricEvalDetailType) - \(.evalDetail.metricPath) -- \(.triggerEnabled) - \(.minimumTriggers)"
        );
      # Construct the final output object
      {
        "id-name": ("\(.id) - \(.name)"),
        # "id": $parent.id,
        # "name": $parent.name,
        "criteria": {
          "critical": {
            "combination": "\($parent.evalCriterias.criticalCriteria.conditionAggregationType) - \($parent.evalCriterias.criticalCriteria.conditionExpression)",
            "conditions": (
              $parent.evalCriterias.criticalCriteria.conditions | extract_conditions
            )
          },
          "warning": {
            "combination": "\($parent.evalCriterias.criticalCriteria.conditionAggregationType) - \($parent.evalCriterias.criticalCriteria.conditionExpression)",
            "conditions": (
              $parent.evalCriterias.warningCriteria.conditions | extract_conditions
            )
          }
        }
      }
    '
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
outputHRData
