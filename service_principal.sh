#!/usr/bin/env bash
# One service principal for the whole room, for attendees who are not in the tenant.
#
#   bash service_principal.sh create     # app + SP + role assignments + a short-lived secret
#   bash service_principal.sh show       # what exists, which roles, when the secret expires
#   bash service_principal.sh rotate     # new secret, same principal and roles
#   bash service_principal.sh delete     # remove the app, the SP and every role assignment
#
# READ THIS BEFORE USING IT.
#
# This is the weaker option and the workshop says so out loud. One credential for thirty people
# means: no attribution (every action in the audit log is the same principal), no per-attendee
# revocation, and any attendee can delete any other attendee's agents and vector stores. That is
# precisely the finding Session 4 asks the room to write down about the three demo agents.
#
# Use it when attendees cannot sign in to the tenant - external conference audiences, mainly. If
# they CAN be invited as guests, `az login` with their own identity is better on every axis, and
# the notebooks work unchanged either way.
#
# Least privilege, concretely. The principal gets exactly two things:
#
#   1. a CUSTOM role on each endpoint that can read it and score it, and nothing else
#   2. "Azure AI User" on the AI Services account - agents, threads, files, vector stores
#
# It deliberately does NOT get "AzureML Data Scientist", which the older setup instructions used.
# That built-in role grants workspaces/*/write and workspaces/*/delete. Scoped to an endpoint it
# still lets any attendee DELETE the endpoint and end the session for the whole room. Scoring needs
# read + score/action, so that is all the custom role contains.
#
# Reader on the resource group is opt-in (--with-reader) and off by default: only notebook 4's
# role-assignment cell wants it, that cell shells out to the az CLI, and Colab has no az CLI - so
# for a Colab audience it would be permission granted for something nobody can run.
#
# Other mitigations:
#   * the secret expires in 2 days by default (SECRET_DAYS), not the 1-2 years az defaults to
#   * nothing is granted at subscription scope
#   * `delete` removes the role assignments and the custom role, which `az ad app delete` does not
set -euo pipefail

RG=${RG:-docintel-ml-rg}
APP_NAME=${APP_NAME:-genai-workshop-attendee}
SECRET_DAYS=${SECRET_DAYS:-2}
AI_USER_ROLE=53ca6127-db72-4b80-b1b0-d745d6d5456d       # "Azure AI User": agents, files, vector stores
SCORER_ROLE=${SCORER_ROLE:-"GenAI Workshop Endpoint Scorer"}
WITH_READER=0
[ "${2:-}" = "--with-reader" ] && WITH_READER=1

WS=$(az ml workspace list -g "$RG" --query "[0].name" -o tsv 2>/dev/null | tr -d '\r' || true)
SUB=$(az account show --query id -o tsv | tr -d '\r')
TENANT=$(az account show --query tenantId -o tsv | tr -d '\r')

app_id()  { az ad app list --display-name "$APP_NAME" --query "[0].appId" -o tsv 2>/dev/null; }
sp_oid()  { az ad sp show --id "$1" --query id -o tsv 2>/dev/null; }

scopes() {
  # Everything the notebooks touch, and nothing else.
  az group show -n "$RG" --query id -o tsv                                    # Reader (notebook 4)
  az cognitiveservices account list -g "$RG" \
     --query "[?kind=='AIServices'].id | [0]" -o tsv                          # Azure AI User
  if [ -n "$WS" ]; then                                                       # scoring, if they exist
    for e in docintel-qwen employee-from-scratch; do
      az ml online-endpoint show -n "$e" -g "$RG" -w "$WS" --query id -o tsv 2>/dev/null || true
    done
  fi
}

ensure_scorer_role() {
  # A role that can read an endpoint and call it, and cannot change or delete it.
  if az role definition list -n "$SCORER_ROLE" --query "[0].roleName" -o tsv 2>/dev/null | grep -q .; then
    echo "  custom role '$SCORER_ROLE' already defined"
    return
  fi
  echo "  defining custom role '$SCORER_ROLE'"
  cat > /tmp/scorer-role.json <<JSON
{
  "Name": "$SCORER_ROLE",
  "Description": "Read and score the workshop's managed online endpoints. No write, no delete, no keys.",
  "Actions": [
    "Microsoft.MachineLearningServices/workspaces/onlineEndpoints/read",
    "Microsoft.MachineLearningServices/workspaces/onlineEndpoints/score/action"
  ],
  "NotActions": [],
  "AssignableScopes": ["/subscriptions/$SUB"]
}
JSON
  az role definition create --role-definition /tmp/scorer-role.json -o none
  rm -f /tmp/scorer-role.json
  sleep 20                                   # a new role definition is not instantly assignable
}

assign() {                                   # assign <sp-object-id>
  local oid=$1 ais_scope eps
  ais_scope=$(az cognitiveservices account list -g "$RG" --query "[?kind=='AIServices'].id | [0]" -o tsv | tr -d '\r')

  MSYS_NO_PATHCONV=1 az role assignment create --assignee-object-id "$oid" \
    --assignee-principal-type ServicePrincipal --role "$AI_USER_ROLE" --scope "$ais_scope" -o none
  echo "  Azure AI User on the AI Services account"

  # The endpoints may not exist yet - endpoints.sh up creates them. Re-run this to pick them up.
  # A missing role here is the "connection refused" of the workshop: the notebook gets a valid
  # token and a 403, which reads like a network problem and is not one.
  eps=$(scopes | grep onlineEndpoints || true)
  if [ -n "$eps" ]; then
    ensure_scorer_role
    for scope in $eps; do
      MSYS_NO_PATHCONV=1 az role assignment create --assignee-object-id "$oid" \
        --assignee-principal-type ServicePrincipal --role "$SCORER_ROLE" --scope "$scope" -o none
      echo "  $SCORER_ROLE on ${scope##*/}"
    done
  else
    echo "  no endpoints yet - run 'bash endpoints.sh up', then re-run this to grant scoring"
  fi

  if [ "$WITH_READER" = "1" ]; then
    MSYS_NO_PATHCONV=1 az role assignment create --assignee-object-id "$oid" \
      --assignee-principal-type ServicePrincipal --role Reader \
      --scope "$(az group show -n "$RG" --query id -o tsv | tr -d '\r')" -o none
    echo "  Reader on the resource group (notebook 4, local only)"
  fi
}

case "${1:-}" in
  create)
    APP=$(app_id)
    if [ -z "$APP" ]; then
      echo "creating app registration $APP_NAME"
      APP=$(az ad app create --display-name "$APP_NAME" --query appId -o tsv | tr -d '\r')
      az ad sp create --id "$APP" -o none
      sleep 10                                  # the SP is not immediately visible to RBAC
    else
      echo "app $APP_NAME already exists ($APP)"
    fi
    OID=$(sp_oid "$APP")

    echo "assigning roles"
    assign "$OID"

    END=$(python -c "import datetime;print((datetime.datetime.utcnow()+datetime.timedelta(days=$SECRET_DAYS)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
    SECRET=$(az ad app credential reset --id "$APP" --append --display-name workshop \
             --end-date "$END" --query password -o tsv | tr -d '\r')

    cat <<EOF

================================================================================
Give attendees these three values. The secret is shown ONCE and expires $END.
================================================================================
AZURE_TENANT_ID=$TENANT
AZURE_CLIENT_ID=$APP
AZURE_CLIENT_SECRET=$SECRET
================================================================================
In the notebook, the first cell prompts for them - attendees paste, nothing is
typed into a cell that gets saved. Do not put these in a slide that is recorded.

Run 'bash service_principal.sh delete' when the session is over.
EOF
    ;;

  show)
    APP=$(app_id)
    [ -z "$APP" ] && { echo "no app named $APP_NAME"; exit 0; }
    OID=$(sp_oid "$APP")
    echo "app        $APP_NAME ($APP)"
    echo "sp object  $OID"
    echo "tenant     $TENANT"
    echo
    echo "secret expiry:"
    az ad app credential list --id "$APP" --query "[].{name:displayName,expires:endDateTime}" -o table
    echo
    echo "role assignments:"
    az role assignment list --assignee "$APP" --all \
      --query "[].{role:roleDefinitionName,scope:scope}" -o table
    ;;

  rotate)
    APP=$(app_id); [ -z "$APP" ] && { echo "no app named $APP_NAME - run create"; exit 1; }
    END=$(python -c "import datetime;print((datetime.datetime.utcnow()+datetime.timedelta(days=$SECRET_DAYS)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
    SECRET=$(az ad app credential reset --id "$APP" --append --display-name workshop \
             --end-date "$END" --query password -o tsv | tr -d '\r')
    echo "AZURE_TENANT_ID=$TENANT"
    echo "AZURE_CLIENT_ID=$APP"
    echo "AZURE_CLIENT_SECRET=$SECRET"
    echo "expires $END"
    ;;

  delete)
    APP=$(app_id); [ -z "$APP" ] && { echo "nothing to delete"; exit 0; }
    echo "removing role assignments"
    az role assignment delete --assignee "$APP" --all -o none 2>/dev/null || true
    echo "deleting app and service principal"
    az ad app delete --id "$APP"
    # The custom role definition outlives the principal. Remove it, unless something still uses it.
    if az role definition list -n "$SCORER_ROLE" --query "[0].roleName" -o tsv 2>/dev/null | grep -q .; then
      if [ -z "$(az role assignment list --role "$SCORER_ROLE" --all -o tsv 2>/dev/null)" ]; then
        az role definition delete -n "$SCORER_ROLE" -o none && echo "removed custom role $SCORER_ROLE"
      else
        echo "custom role $SCORER_ROLE is still assigned elsewhere - left in place"
      fi
    fi
    echo "done - verify:"
    az role assignment list --assignee "$APP" --all -o tsv 2>/dev/null | head -1 || echo "  no assignments remain"
    ;;

  *) sed -n '2,10p' "$0"; exit 1 ;;
esac
