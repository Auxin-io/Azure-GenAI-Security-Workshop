#!/usr/bin/env bash
# Fetch the workshop content, publish only the attendee-facing part, then serve JupyterLab.
#
# Content is pulled at boot rather than baked into the image, so fixing a notebook the morning of
# the session is a restart, not a rebuild-and-redeploy.
set -euo pipefail

REPO=${WORKSHOP_REPO:-https://github.com/Auxin-io/Azure-GenAI-Security-Workshop.git}
SRC=/workshop/repo
PUB=/workshop/content        # what attendees see, and the only thing Jupyter is rooted at

if [ -d "$SRC/.git" ]; then
  git -C "$SRC" pull --ff-only || echo "pull failed - serving the copy already here"
else
  git clone --depth 1 "$REPO" "$SRC" || { echo "clone failed"; exit 1; }
fi

# Attendees open a link and run notebooks. Nothing else. The facilitator scripts - endpoints.sh,
# service_principal.sh, host/, the notebook generator - are deliberately NOT published here: an
# attendee who opens service_principal.sh and wonders whether to run it has been failed by the
# setup, not by their own curiosity. Terminals are off for the same reason.
mkdir -p "$PUB"
rm -rf "$PUB"/*.ipynb "$PUB"/data "$PUB"/workshop.py "$PUB"/START-HERE.md "$PUB"/*.md
cp "$SRC"/0[1-4]_*.ipynb "$PUB"/
cp "$SRC"/workshop.py "$PUB"/
cp -r "$SRC"/data "$PUB"/data
cp "$SRC"/session2-threat-model-worksheet.md "$PUB"/ 2>/dev/null || true

cat > "$PUB/START-HERE.md" <<'MD'
# GenAI Security Workshop

Open a notebook from the file list on the left and run the cells top to bottom.

| | |
|---|---|
| `01_architecture_and_data.ipynb` | Session 1 - three ways to give a model knowledge, then build an agent that uses all three |
| `02_threat_modeling.ipynb` | Session 2 - run an attack harness, poison a document corpus, harden the agent |
| `03_guarded_agent.ipynb` | Session 3 - build an agent with a write tool, a human approval gate and a harness |
| `04_govern_and_observe.ipynb` | Session 4 - agent inventory, enforcement evidence, classify an activity log |

**You do not need an Azure account and there is nothing to install or configure.**
This environment already holds its own identity, so the first cell just works.

Some cells ask you for a short name. That is so your agents and vector stores do not
collide with anyone else's - any name will do.

Anything you create, you delete at the end of the notebook. Please run those last cells.

Session 2 also has a paper exercise: `session2-threat-model-worksheet.md`.
MD

cd "$PUB"

# One shared token on the URL. It is the only thing attendees need, and it grants access to this
# container, NOT to Azure - the Azure credential is the managed identity and never leaves the
# container. Rotating it is a restart with a new value; it cannot be exfiltrated by copying a cell.
TOKEN=${JUPYTER_TOKEN:?set JUPYTER_TOKEN on the container app}

exec jupyter lab \
  --ip=0.0.0.0 --port=8888 --no-browser \
  --ServerApp.token="$TOKEN" \
  --ServerApp.password='' \
  --ServerApp.allow_origin='*' \
  --ServerApp.root_dir="$PUB" \
  --ServerApp.terminals_enabled=False \
  --ServerApp.default_url='/lab/tree/START-HERE.md' \
  --ServerApp.disable_check_xsrf=False
