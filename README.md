# GenAI Security Workshop — hands-on notebooks

Four notebooks, one per session, all running against the **live Azure resources**
of the three demo projects — no mocks, no API keys, your own Entra identity:

| Session | Notebook | Exercise | Uses |
|---|---|---|---|
| 1 Architecture & Data | `01_architecture_and_data.ipynb` | design a Security Architect agent: data → RAG → model → agent → memory → identity → permissions → approval | finance endpoint (base vs tuned), employee endpoint, HR RAG agent, finance agent |
| 2 Zero Trust, Threats & Attack Paths | `02_threat_modeling.ipynb` | threat-model the agentic architecture; run an attack harness; poison a RAG corpus and harden the agent | finance agent, your own copy of the HR agent + vector store |
| 3 Building, Testing & Monitoring | `03_guarded_agent.ipynb` | build an agent with a read tool and a write tool, add a human-approval gate, observe the trace, decide alerts | employee endpoint via OpenAPI + managed identity, function tool with `requires_action` |
| 4 Governing & Observing | `04_govern_and_observe.ipynb` | agent inventory, enforcement evidence (RBAC), classify an activity log Allow / Monitor / Require approval / Block, write the four-layer guardrail policy | all three agents, role assignments, a real activity log |

The demo projects behind them:
[Azure-FineTuning-Foundry-Agent](https://github.com/Auxin-io/Azure-FineTuning-Foundry-Agent) ·
[Azure-Employee-Pretraining](https://github.com/Auxin-io/Azure-Employee-Pretraining) ·
[Azure-HR-RAG](https://github.com/Auxin-io/Azure-HR-RAG).
Diagrams: the Lucid *Azure architecture* and *DFD - Azure three-track architecture* documents.

---

## Run in Google Colab (no install)

| Session | |
|---|---|
| 1 | [![Open In Colab](https://colab.research.google.com/assets/colab-badge.svg)](https://colab.research.google.com/github/Auxin-io/Azure-GenAI-Security-Workshop/blob/main/01_architecture_and_data.ipynb) |
| 2 | [![Open In Colab](https://colab.research.google.com/assets/colab-badge.svg)](https://colab.research.google.com/github/Auxin-io/Azure-GenAI-Security-Workshop/blob/main/02_threat_modeling.ipynb) |
| 3 | [![Open In Colab](https://colab.research.google.com/assets/colab-badge.svg)](https://colab.research.google.com/github/Auxin-io/Azure-GenAI-Security-Workshop/blob/main/03_guarded_agent.ipynb) |
| 4 | [![Open In Colab](https://colab.research.google.com/assets/colab-badge.svg)](https://colab.research.google.com/github/Auxin-io/Azure-GenAI-Security-Workshop/blob/main/04_govern_and_observe.ipynb) |

The first cell installs the SDKs and fetches `workshop.py` + `data/` from this repo. The second cell prints a
**device code**: open https://microsoft.com/devicelogin, enter the code, sign in with your workshop-tenant
account. Everything else is identical to running locally. Notebook 4's role-assignment cell needs the Azure
CLI, which Colab does not have; it prints a note and you use the sample output in the README instead.

## Attendee setup — local (5 minutes)

1. Python 3.11+ and the Azure CLI. Sign in to the workshop tenant:
   ```bash
   az login
   ```
2. Install and start:
   ```bash
   pip install -r requirements.txt
   jupyter lab          # or open the folder in VS Code
   ```
3. Open `01_architecture_and_data.ipynb` and run the first cell. It prints who you are signed in as; if it does, everything else will work.

Windows: run the notebooks from a normal Python kernel; nothing here needs Git Bash.

What you can and cannot do: you can call the endpoints, run the shared agents, and create **your own** agents, vector stores and threads (they carry your alias). Notebooks 2 and 3 delete what they create at the end — run those cells.

---

## Facilitator setup (once, before the workshop)

Attendees need two data-plane roles. Put them in a group and grant the group:

```bash
az ad group create --display-name genai-workshop-attendees --mail-nickname genai-workshop-attendees
GRP=$(az ad group show -g genai-workshop-attendees --query id -o tsv)
# add members: az ad group member add -g genai-workshop-attendees --member-id <user-object-id>

AIS=$(az cognitiveservices account list -g docintel-ml-rg --query "[?kind=='AIServices'].id | [0]" -o tsv)
WS=$(az ml workspace list -g docintel-ml-rg --query "[0].name" -o tsv)
for EP in docintel-qwen employee-from-scratch; do
  SCOPE=$(az ml online-endpoint show -n $EP -g docintel-ml-rg -w $WS --query id -o tsv)
  MSYS_NO_PATHCONV=1 az role assignment create --assignee-object-id $GRP --assignee-principal-type Group \
    --role "AzureML Data Scientist" --scope $SCOPE                       # score the endpoints
done
MSYS_NO_PATHCONV=1 az role assignment create --assignee-object-id $GRP --assignee-principal-type Group \
  --role 53ca6127-db72-4b80-b1b0-d745d6d5456d --scope $AIS               # Azure AI User: agents, files, vector stores
MSYS_NO_PATHCONV=1 az role assignment create --assignee-object-id $GRP --assignee-principal-type Group \
  --role Reader --scope $(az group show -n docintel-ml-rg --query id -o tsv)   # notebook 4: list role assignments
```

Allow 10 minutes for the roles to propagate.

Capacity: `gpt-4.1-mini` is deployed at **150K tokens/min** (`terraform/main.tf`, `capacity = 150`); that is enough for ~30 attendees running the notebooks concurrently. The helper retries on 429. Both endpoints are single-instance — the finance one takes ~1 s per question on the T4, the employee one ~0.2 s on a DS1.

Before the session:
```bash
python build_notebooks.py                       # regenerate the .ipynb from build_notebooks.py after any edit
python run_notebook.py 01_architecture_and_data.ipynb   # dry-run every code cell (set WORKSHOP_AUTO=1 for notebook 3)
```

After the session: attendees' leftovers are named `hr-agent-<alias>`, `hr-poisoned-<alias>`, `guarded-agent-<alias>`; list and delete anything they forgot:
```python
import workshop as w; c = w.agents_client()
for a in c.list_agents():
    if a.name.startswith(("hr-agent-", "guarded-agent-")): c.delete_agent(a.id)
for s in c.vector_stores.list():
    if s.name.startswith("hr-poisoned-"): c.vector_stores.delete(s.id)
```

---

## What each notebook proves (answer key, short)

| Notebook | The moment |
|---|---|
| 01 | `BASE` says "I'd need the document", `TUNED` says `INV-35089, $47,186.04` — the facts are in the weights. The from-scratch model answers a France question with an expense report — it knows nothing else. The HR agent cites `doc-hr-001.txt` and refuses parental leave. |
| 02 | Harness: wrong-premise and extraction get through (model confabulates / lists everything it knows); jailbreak and instruction-leak are stopped by the content filter (`run incomplete`); scope-escape is refused by the instructions. Poisoned `HR-209 revision` is cited as fact with a password-exfil line; hardened instructions surface the conflict and both files. |
| 03 | The read tool runs unattended; `approve_expense` stops the run in `requires_action` until a human answers; a vague "sort it out" does not trigger the write tool. Run steps show tokens and steps per turn. |
| 04 | Inventory shows three agents, one project, one shared identity; role listing shows the same `AzureML Data Scientist` principal on both endpoints and a user with account-wide Foundry User — the per-agent separation from the threat model is the missing control. |

---

## Files

```
workshop.py            helpers: credential, score(), agents_client(), ask(), describe_steps()
build_notebooks.py     source of the four notebooks
run_notebook.py        executes a notebook's code cells without Jupyter (verification)
0[1-4]_*.ipynb         the sessions
data/hr/               the ten HR OCR texts (synthetic) used to build your own vector store
data/poison/           written by notebook 2
```
