#!/usr/bin/env bash
# Remove a temporary workshop credential and the workshop role assignments from an app
# registration that is NOT dedicated to the workshop.
#
#   bash revoke_workshop_credential.sh show     # what is on the app right now
#   bash revoke_workshop_credential.sh revoke   # remove the workshop credential and roles
#
# Context. When the tenant blocks app registration, the fallback is to borrow an app registration
# the account already owns. That app has its own purpose and its own permissions, so everything the
# workshop adds has to come back off the same day - this script is that half.
#
# It only ever REMOVES. Issuing the credential is a deliberate manual step, documented in the
# README, so that the secret is created by a person and never lands in a script, a log or a
# transcript.
#
# The credential is matched by display name, so the app's own credentials are never touched. On
# azure-scan those are `vm shutdown` and `backup`, and deleting either breaks live automation.
set -euo pipefail

APP=${APP:-ad2f64f3-e752-4396-958f-2888095c65e1}          # azure-scan
RG=${RG:-docintel-ml-rg}
CRED_NAME=${CRED_NAME:-workshop-temporary}
AI_USER_ROLE=53ca6127-db72-4b80-b1b0-d745d6d5456d          # Azure AI User
SCORER_ROLE=${SCORER_ROLE:-"GenAI Workshop Endpoint Scorer"}

WS=$(az ml workspace list -g "$RG" --query "[0].name" -o tsv 2>/dev/null | tr -d '\r' || true)

endpoint_scopes() {
  [ -z "$WS" ] && return 0
  for e in docintel-qwen employee-from-scratch; do
    az ml online-endpoint show -n "$e" -g "$RG" -w "$WS" --query id -o tsv 2>/dev/null || true
  done
}

case "${1:-show}" in
  show)
    echo "credentials on the app:"
    az ad app credential list --id "$APP" \
      --query "[].{name:displayName,keyId:keyId,expires:endDateTime}" -o table
    echo
    echo "role assignments on its service principal:"
    az role assignment list --assignee "$APP" --all \
      --query "[].{role:roleDefinitionName,scope:scope}" -o table
    echo
    echo "anything named '$CRED_NAME' above is the workshop's and should not outlive the session."
    ;;

  revoke)
    FOUND=$(az ad app credential list --id "$APP" \
            --query "[?displayName=='$CRED_NAME'].keyId" -o tsv | tr -d '\r')
    if [ -z "$FOUND" ]; then
      echo "no credential named '$CRED_NAME' on this app"
    else
      for k in $FOUND; do
        echo "deleting workshop credential $k"
        az ad app credential delete --id "$APP" --key-id "$k"
      done
    fi

    echo "removing workshop role assignments"
    AIS=$(az cognitiveservices account list -g "$RG" --query "[?kind=='AIServices'].id | [0]" -o tsv | tr -d '\r')
    MSYS_NO_PATHCONV=1 az role assignment delete --assignee "$APP" --role "$AI_USER_ROLE" \
      --scope "$AIS" -o none 2>/dev/null || echo "  (Azure AI User assignment not present)"
    for scope in $(endpoint_scopes); do
      MSYS_NO_PATHCONV=1 az role assignment delete --assignee "$APP" --role "$SCORER_ROLE" \
        --scope "$scope" -o none 2>/dev/null || true
    done

    echo
    echo "verifying. The app's own credentials must still be here, the workshop one must be gone,"
    echo "and the only roles left should be the ones the app had before the workshop:"
    az ad app credential list --id "$APP" \
      --query "[].{name:displayName,expires:endDateTime}" -o table
    echo
    az role assignment list --assignee "$APP" --all \
      --query "[].{role:roleDefinitionName,scope:scope}" -o table
    ;;

  *) sed -n '2,6p' "$0"; exit 1 ;;
esac
