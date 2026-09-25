#!/usr/bin/env bash
# Bring the two managed online endpoints up for a session, and take them down afterwards.
#
#   bash endpoints.sh up       # ~15-20 min, both endpoints; run before the session
#   bash endpoints.sh status   # what exists right now
#   bash endpoints.sh down     # delete both; run the moment the session ends
#
# Why this exists as a script rather than a standing deployment: the finance endpoint runs on a
# Standard_NC4as_T4_v3, which is $0.526/hr - about $379/month if it is left up. The employee one
# adds $53/month. A three-hour workshop costs $1.80. There is no reason for them to exist on any
# other day, and the models stay registered in the workspace either way, so bringing them back is
# a deployment, never a retrain.
#
# `az ml online-deployment delete` returns exit 0 while the endpoint keeps routing 100% of traffic
# to the deployment you just deleted - delete the ENDPOINT, and verify with `status` afterwards.
set -euo pipefail

RG=${RG:-docintel-ml-rg}
WS=${WS:-$(az ml workspace list -g "$RG" --query "[0].name" -o tsv | tr -d '\r')}
ROOT=${ROOT:-$(cd "$(dirname "$0")/.." && pwd)}      # the folder holding the Azure-* repos

FINANCE_DIR="$ROOT/Azure-FineTuning-Foundry-Agent/serving"
EMPLOYEE_DIR="$ROOT/Azure-Employee-Pretraining/serving"

usage() { sed -n '2,12p' "$0"; exit 1; }

status() {
  echo "workspace: $WS"
  local eps
  eps=$(az ml online-endpoint list -g "$RG" -w "$WS" --query "[].name" -o tsv | tr -d '\r')
  if [ -z "$eps" ]; then
    echo "  no online endpoints - nothing is billing"
    return
  fi
  for e in $eps; do
    echo "  $e"
    az ml online-deployment list -g "$RG" -w "$WS" -e "$e" \
      -o tsv --query "[].{n:name,s:provisioning_state,i:instance_type,c:instance_count}" \
      | sed 's/^/     /'
  done
}

up_one() {                                    # up_one <dir> <endpoint-name>
  local dir=$1 name=$2
  if az ml online-endpoint show -n "$name" -g "$RG" -w "$WS" >/dev/null 2>&1; then
    echo "== $name already exists, skipping"
    return
  fi
  echo "== creating $name"
  az ml online-endpoint create -g "$RG" -w "$WS" -f "$dir/endpoint.yml"
  # --all-traffic, or the endpoint comes up routing 0% and every call 404s.
  az ml online-deployment create -g "$RG" -w "$WS" -f "$dir/deployment.yml" --all-traffic
}

case "${1:-}" in
  up)
    echo "creating both endpoints - 15-20 min, and the meter starts now"
    up_one "$EMPLOYEE_DIR" employee-from-scratch     # cheap and slow to warm: start it first
    up_one "$FINANCE_DIR"  docintel-qwen
    echo
    status
    echo
    # workshop.py hardcodes the scoring URIs. If a recreated endpoint lands on a different region
    # or suffix, every notebook fails with a connection error and the cause is not obvious.
    for e in docintel-qwen employee-from-scratch; do
      uri=$(az ml online-endpoint show -n "$e" -g "$RG" -w "$WS" --query scoring_uri -o tsv | tr -d '\r')
      if grep -q "$uri" "$(dirname "$0")/workshop.py"; then
        echo "  $e scoring_uri matches workshop.py"
      else
        echo "  WARNING: $e is at $uri"
        echo "           update CONFIG[\"endpoints\"] in workshop.py or every notebook fails"
      fi
    done
    echo
    echo "Grant the attendee group scoring rights (see README, facilitator setup), then smoke-test:"
    echo "  python -c \"import workshop as w; print(w.score('finance','How much do we owe Xenon Energy?'))\""
    ;;
  down)
    for e in docintel-qwen employee-from-scratch; do
      if az ml online-endpoint show -n "$e" -g "$RG" -w "$WS" >/dev/null 2>&1; then
        echo "== deleting $e"
        az ml online-endpoint delete -n "$e" -g "$RG" -w "$WS" --yes
      else
        echo "== $e not present"
      fi
    done
    echo
    echo "verifying - this is the step people skip:"
    status
    ;;
  status) status ;;
  *) usage ;;
esac
