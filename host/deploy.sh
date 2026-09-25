#!/usr/bin/env bash
# Stand up (and tear down) the notebook host attendees connect to.
#
#   bash host/deploy.sh up      # build the image, deploy, print the URL and token
#   bash host/deploy.sh status  # replicas, URL, and which identity is attached
#   bash host/deploy.sh down    # scale to zero - keeps the app, stops the cost
#   bash host/deploy.sh destroy # remove the container app entirely
#
# WHY THIS EXISTS
#
# The tenant blocks app registration and this account holds no Entra directory role, so a
# conventional service principal cannot be created. A user-assigned MANAGED identity can be,
# because it is an Azure resource under Azure RBAC rather than an object in the directory.
#
# The trade is that a managed identity only authenticates from inside Azure - there is no secret to
# paste into Colab. So the notebooks run here instead, and that turns out to be the better position:
#
#   * nothing is handed out. No client secret to leak, expire, or forget to revoke.
#   * least privilege is exact: the identity holds Foundry User on one AI Services account and a
#     custom read+score role on the two endpoints. Nothing else.
#   * revoking is one role-assignment delete, and it is instant for everyone at once.
#
# Attendees get a URL and a token. That token grants access to THIS CONTAINER, not to Azure.
set -euo pipefail

RG=${RG:-docintel-ml-rg}
LOC=${LOC:-eastus2}
ENV_NAME=${ENV_NAME:-docintel-cae-eus2}                 # reuse the existing Container Apps env
APP=${APP:-workshop-notebooks}
MI_NAME=${MI_NAME:-workshop-notebook-mi}
ACR=${ACR:-docintelacrdggcb4}
IMAGE_TAG=${IMAGE_TAG:-v1}
HERE=$(cd "$(dirname "$0")" && pwd)

case "${1:-}" in
  up)
    # resource id, used for --user-assigned and --registry-identity; both need
    # MSYS_NO_PATHCONV or Git Bash turns the leading / into C:/...
    MI_ID=$(az identity show -g "$RG" -n "$MI_NAME" --query id -o tsv | tr -d '\r')
    MI_CLIENT=$(az identity show -g "$RG" -n "$MI_NAME" --query clientId -o tsv | tr -d '\r')
    echo "identity: $MI_NAME ($MI_CLIENT)"

    echo "building the image in ACR (no local Docker needed)"
    az acr build -r "$ACR" -t "workshop-notebooks:$IMAGE_TAG" "$HERE" -o none
    LOGIN=$(az acr show -n "$ACR" --query loginServer -o tsv | tr -d '\r')

    # A fresh token every deploy. Attendees get it from you, not from the repo.
    TOKEN=$(python -c "import secrets;print(secrets.token_urlsafe(18))")

    if az containerapp show -n "$APP" -g "$RG" >/dev/null 2>&1; then
      echo "updating existing container app"
      MSYS_NO_PATHCONV=1 az containerapp update -n "$APP" -g "$RG" \
        --image "$LOGIN/workshop-notebooks:$IMAGE_TAG" \
        --set-env-vars JUPYTER_TOKEN="$TOKEN" AZURE_CLIENT_ID="$MI_CLIENT" -o none
    else
      echo "creating the container app"
      MSYS_NO_PATHCONV=1 az containerapp create -n "$APP" -g "$RG" --environment "$ENV_NAME" \
        --image "$LOGIN/workshop-notebooks:$IMAGE_TAG" \
        --target-port 8888 --ingress external \
        --user-assigned "$MI_ID" \
        --registry-server "$LOGIN" --registry-identity "$MI_ID" \
        --min-replicas 1 --max-replicas 1 \
        --cpu 1 --memory 2Gi \
        --env-vars JUPYTER_TOKEN="$TOKEN" AZURE_CLIENT_ID="$MI_CLIENT" -o none
    fi

    FQDN=$(az containerapp show -n "$APP" -g "$RG" --query properties.configuration.ingress.fqdn -o tsv | tr -d '\r')
    cat <<EOF

================================================================================
Give attendees this one link. Nothing else.
================================================================================
  https://$FQDN/lab?token=$TOKEN
================================================================================
The token opens this container. It is NOT an Azure credential - the Azure
credential is the managed identity and never leaves the container, so a token
that leaks costs you a restart, not an incident.

min-replicas is 1, so it is running and billing (~\$0.03/hr) until:
  bash host/deploy.sh down
EOF
    ;;

  status)
    az containerapp show -n "$APP" -g "$RG" \
      --query "{fqdn:properties.configuration.ingress.fqdn,min:properties.template.scale.minReplicas,max:properties.template.scale.maxReplicas,identity:identity.type}" \
      -o json 2>&1 | head -10
    echo "identity role assignments:"
    OID=$(az identity show -g "$RG" -n "$MI_NAME" --query principalId -o tsv | tr -d '\r')
    az role assignment list --assignee "$OID" --all \
      --query "[].{role:roleDefinitionName,scope:scope}" -o table
    ;;

  down)
    # Scale to zero rather than delete: the app, its URL and its identity wiring survive, so the
    # next session is `up` again with a new token instead of a rebuild.
    az containerapp update -n "$APP" -g "$RG" --min-replicas 0 --max-replicas 0 -o none
    echo "scaled to zero - not billing. 'up' brings it back with a fresh token."
    ;;

  destroy)
    az containerapp delete -n "$APP" -g "$RG" --yes -o none && echo "container app deleted"
    echo "the managed identity and its roles remain - remove with:"
    echo "  az identity delete -g $RG -n $MI_NAME"
    ;;

  *) sed -n '2,8p' "$0"; exit 1 ;;
esac
