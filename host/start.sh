#!/usr/bin/env bash
# Fetch the workshop content, then serve JupyterLab.
#
# Content is pulled at boot rather than baked into the image, so fixing a notebook the morning of
# the session is a restart, not a rebuild-and-redeploy.
set -euo pipefail

REPO=${WORKSHOP_REPO:-https://github.com/Auxin-io/Azure-GenAI-Security-Workshop.git}
DIR=/workshop/content

if [ -d "$DIR/.git" ]; then
  git -C "$DIR" pull --ff-only || echo "pull failed - serving the copy already here"
else
  git clone --depth 1 "$REPO" "$DIR" || { echo "clone failed"; exit 1; }
fi
cd "$DIR"

# One shared token on the URL. It is the only thing attendees need, and it grants access to this
# container, NOT to Azure - the Azure credential is the managed identity and never leaves the
# container. Rotating it is a restart with a new value; it cannot be exfiltrated by copying a cell.
TOKEN=${JUPYTER_TOKEN:?set JUPYTER_TOKEN on the container app}

# --collaborative is deliberately off: thirty people editing one document is not the exercise, and
# each attendee should be running their own cells against their own agent.
exec jupyter lab \
  --ip=0.0.0.0 --port=8888 --no-browser \
  --ServerApp.token="$TOKEN" \
  --ServerApp.password='' \
  --ServerApp.allow_origin='*' \
  --ServerApp.root_dir="$DIR" \
  --ServerApp.terminals_enabled=False \
  --ServerApp.disable_check_xsrf=False
