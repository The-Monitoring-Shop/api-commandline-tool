#!/bin/bash
# ---------------------------------------------------------------------------
# For every node of an application: is it reporting metrics during the last
# month (30 d) and the last week (7 d)?
#
# Recipe: run from the recipes/ folder of ACT (act.sh is expected at ../act.sh,
#         like the other recipes). Use -x to point to another act.sh.
#
# Usage:  ./check_node_metrics.sh -a "<application>" [-o result.json] [-c result.csv]
#         [-x /path/to/act.sh] [-E <act environment>] [-m <days month>] [-w <days week>]
#         [-k <dir>]  keep raw controller responses in <dir> (for troubleshooting)
#
# Requires: act.sh (with OAuth plugin if you use an API client), jq.
#
# Per time window it makes 3 wildcard calls (not one per node):
#   Overall Application Performance|*|Individual Nodes|*|Calls per Minute
#   Application Infrastructure Performance|*|Individual Nodes|*|Agent|App|Availability
#   Application Infrastructure Performance|*|Individual Nodes|*|Agent|Machine|Availability
# "sum" of Calls per Minute = total calls in the window;
# "sum" of Availability     = number of minutes the agent reported.
#
# Status (decided on the week window, month used for context):
#   OK                              calls in the last week (or Machine Agent node reporting)
#   AGENT_UP_NO_CALLS_LAST_7_DAYS   agent reports, calls only earlier in the month
#   AGENT_UP_NO_CALLS_LAST_30_DAYS  agent reports, no calls during the whole month
#   NO_DATA_LAST_7_DAYS             nothing in the last week, something earlier in the month
#   NO_DATA_LAST_30_DAYS            nothing at all during the month
# ---------------------------------------------------------------------------
set -u
ACT="../act.sh"; APP=""; OUT_JSON=""; OUT_CSV=""; ENV_ARGS=(); MONTH_DAYS=30; WEEK_DAYS=7; KEEP_DIR=""

while getopts "a:o:c:x:E:m:w:k:" opt; do
  case "$opt" in
    a) APP="$OPTARG" ;;  o) OUT_JSON="$OPTARG" ;;  c) OUT_CSV="$OPTARG" ;;
    x) ACT="$OPTARG" ;;  E) ENV_ARGS=(-E "$OPTARG") ;;
    m) MONTH_DAYS="$OPTARG" ;;  w) WEEK_DAYS="$OPTARG" ;;  k) KEEP_DIR="$OPTARG" ;;
    *) echo "Usage: $0 -a <application> [-o out.json] [-c out.csv] [-x act.sh] [-E env]" >&2; exit 2 ;;
  esac
done
[ -f "$ACT" ] || { echo "ERROR: act.sh not found at $ACT (run from recipes/ or use -x <path to act.sh>)" >&2; exit 2; }
[ -z "$APP" ] && { echo "ERROR: application (-a) is required" >&2; exit 2; }
command -v jq >/dev/null || { echo "ERROR: jq not found (winget install jqlang.jq)" >&2; exit 2; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

act() { bash "$ACT" "${ENV_ARGS[@]}" -N -Q "$@"; }

# fetch <file> <cmd...> : run act, make sure the result is a JSON array
fetch() {
  local F="$1"; shift
  act "$@" | tr -d '\r' > "$F"
  if ! jq -e 'type=="array"' "$F" >/dev/null 2>&1; then
    echo "ERROR calling: act.sh $*" >&2; head -c 500 "$F" >&2; echo >&2; exit 1
  fi
}

echo "Nodes of '$APP'..." >&2
fetch "$TMP/nodes.json" node list "$APP"
echo "  $(jq length "$TMP/nodes.json") nodes" >&2

declare -A PATHS=(
  [calls]="Overall Application Performance|*|Individual Nodes|*|Calls per Minute"
  [app]="Application Infrastructure Performance|*|Individual Nodes|*|Agent|App|Availability"
  [machine]="Application Infrastructure Performance|*|Individual Nodes|*|Agent|Machine|Availability"
)
for W in month week; do
  [ "$W" = month ] && MIN=$(( MONTH_DAYS * 1440 )) || MIN=$(( WEEK_DAYS * 1440 ))
  for K in calls app machine; do
    echo "Metrics: $W ($MIN min) / $K..." >&2
    fetch "$TMP/${W}_${K}.json" metric get -a "$APP" -d "$MIN" "${PATHS[$K]}"
  done
done

# Build "tier|node" -> sum lookup and join with the node list
jq -n \
  --slurpfile nodes "$TMP/nodes.json" \
  --slurpfile mc "$TMP/month_calls.json" --slurpfile ma "$TMP/month_app.json" --slurpfile mm "$TMP/month_machine.json" \
  --slurpfile wc "$TMP/week_calls.json"  --slurpfile wa "$TMP/week_app.json"  --slurpfile wm "$TMP/week_machine.json" \
  --arg md "$MONTH_DAYS" --arg wd "$WEEK_DAYS" '
  def lookup(a): a[0] | map(select(.metricPath != null) | (.metricPath | split("|")) as $p
                   | { key: ($p[1] + "|" + $p[3]), value: ((.metricValues // [])[0].sum // 0) })
                 | from_entries;
  def win(c; a; m; k): { calls: (lookup(c)[k] // 0), appAgentMinutes: (lookup(a)[k] // 0), machineAgentMinutes: (lookup(m)[k] // 0) }
                       | . + { hasData: (.calls > 0 or .appAgentMinutes > 0 or .machineAgentMinutes > 0) };
  $nodes[0] | map(
    (.tierName + "|" + .name) as $k
    | { id, name, tierName, agentType, machineName,
        lastMonth: win($mc; $ma; $mm; $k),
        lastWeek:  win($wc; $wa; $wm; $k) }
    | . + { status: (if .lastWeek.calls > 0 then "OK"
                     elif .lastWeek.hasData and .agentType == "MACHINE_AGENT" then "OK"
                     elif .lastWeek.hasData and .lastMonth.calls > 0 then "AGENT_UP_NO_CALLS_LAST_\($wd)_DAYS"
                     elif .lastWeek.hasData then "AGENT_UP_NO_CALLS_LAST_\($md)_DAYS"
                     elif .lastMonth.hasData then "NO_DATA_LAST_\($wd)_DAYS"
                     else "NO_DATA_LAST_\($md)_DAYS" end) })
' > "$TMP/result.json"

if [ -n "$KEEP_DIR" ]; then mkdir -p "$KEEP_DIR" && cp "$TMP"/*.json "$KEEP_DIR"/ && echo "Raw responses: $KEEP_DIR" >&2; fi
if [ -n "$OUT_JSON" ]; then cp "$TMP/result.json" "$OUT_JSON"; echo "JSON: $OUT_JSON" >&2; fi
if [ -n "$OUT_CSV" ]; then
  jq -r '(["id","name","tierName","agentType","month_calls","month_appAgentMin","month_machineAgentMin","week_calls","week_appAgentMin","week_machineAgentMin","status"] | @csv),
         (.[] | [.id,.name,.tierName,.agentType,.lastMonth.calls,.lastMonth.appAgentMinutes,.lastMonth.machineAgentMinutes,.lastWeek.calls,.lastWeek.appAgentMinutes,.lastWeek.machineAgentMinutes,.status] | @csv)' \
     "$TMP/result.json" > "$OUT_CSV"
  echo "CSV:  $OUT_CSV" >&2
fi

# Console summary (APP_MIN / MACH_MIN = minutes the App / Machine agent reported)
jq -r '["STATUS","TIER","NODE","AGENT","CALLS_30D","CALLS_7D","APP_MIN_7D","MACH_MIN_7D"], (.[] | [.status,.tierName,.name,.agentType,.lastMonth.calls,.lastWeek.calls,.lastWeek.appAgentMinutes,.lastWeek.machineAgentMinutes]) | @tsv' "$TMP/result.json" > "$TMP/summary.tsv"
column -t -s $'\t' "$TMP/summary.tsv" 2>/dev/null || cat "$TMP/summary.tsv"
