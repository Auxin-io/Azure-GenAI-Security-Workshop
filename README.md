# GenAI Security Workshop — hands-on notebooks

Four notebooks, one per session, running against **live Azure resources**. No mocks, no API keys,
nothing to install.

| Session | Notebook | What attendees do |
|---|---|---|
| **1** Architecture & Data | `01_architecture_and_data.ipynb` | See the same question answered three ways — facts trained into a model, a model that knows nothing else, and a model that searches documents instead. Then **build one agent that uses all three**. |
| **2** Zero Trust, Threats & Attack Paths | `session2-threat-model-worksheet.md` (paper) + `02_threat_modeling.ipynb` | Threat-model the architecture on paper. Then attack the agent five ways — **two attacks succeed** — and poison its document library. |
| **3** Building, Testing & Monitoring | `03_guarded_agent.ipynb` | Give an agent the power to approve an expense, add a human-approval gate, then **build a harness around it** and watch each control block and allow. |
| **4** Governing & Observing | `04_govern_and_observe.ipynb` | Inventory the agents actually running, read the real permissions, check each safety control against the live agents, classify an activity log. |

The systems behind them:
[Azure-FineTuning-Foundry-Agent](https://github.com/Auxin-io/Azure-FineTuning-Foundry-Agent) ·
[Azure-Employee-Pretraining](https://github.com/Auxin-io/Azure-Employee-Pretraining) ·
[Azure-HR-RAG](https://github.com/Auxin-io/Azure-HR-RAG)

---

# For attendees

Two ways in. Your facilitator will say which one you are using.

## 1. The hosted link — nothing to install, nothing to sign in to

Open the link you were given. The notebooks are there and already signed in.

## 2. Google Colab — paste one secret

| Session | |
|---|---|
| 1 | [![Open In Colab](https://colab.research.google.com/assets/colab-badge.svg)](https://colab.research.google.com/github/Auxin-io/Azure-GenAI-Security-Workshop/blob/main/01_architecture_and_data.ipynb) |
| 2 | [![Open In Colab](https://colab.research.google.com/assets/colab-badge.svg)](https://colab.research.google.com/github/Auxin-io/Azure-GenAI-Security-Workshop/blob/main/02_threat_modeling.ipynb) |
| 3 | [![Open In Colab](https://colab.research.google.com/assets/colab-badge.svg)](https://colab.research.google.com/github/Auxin-io/Azure-GenAI-Security-Workshop/blob/main/03_guarded_agent.ipynb) |
| 4 | [![Open In Colab](https://colab.research.google.com/assets/colab-badge.svg)](https://colab.research.google.com/github/Auxin-io/Azure-GenAI-Security-Workshop/blob/main/04_govern_and_observe.ipynb) |

1. **Cell 1** installs the libraries.
2. **Cell 2** asks for the workshop secret. Paste it — it is hidden as you type, so it is never
   saved into the notebook.
3. Run the rest, top to bottom.

**You do not need an Azure account.**

### Worth knowing

- Every cell starts with a comment saying what it does and what to watch for. Read those.
- Some cells ask for a **short name**, so your agents do not collide with anyone else's. Any name
  will do.
- **Run the cleanup cells at the end.** Notebooks 1, 2 and 3 each delete what they created.
- Notebook 4's permissions cell needs the Azure CLI. In Colab it prints a note instead, and you
  read the sample output.

---

# For the facilitator

> **The scripts below are not in this repository.** `endpoints.sh`, `service_principal.sh`,
> `host/` and `build_notebooks.py` stay on the facilitator's machine. Attendees clone this repo —
> the Colab bootstrap does, and so does the notebook host at boot — so it holds only what an
> attendee needs.

## Before every session

```bash
bash endpoints.sh up               # ~30 min. The T4 is the slow one
bash service_principal.sh create   # least-privilege SP + a 2-day secret. Run AFTER endpoints.sh up
bash host/deploy.sh up             # only for the hosted option. Prints a fresh token each time
```

`endpoints.sh up` also re-grants the scoring roles. That matters: **role assignments scoped to an
endpoint are destroyed when the endpoint is deleted**, so every up/down cycle would otherwise leave
the Foundry agents with a 403 on every tool call — which surfaces in a notebook as a run that fails
with no message at all.

## After every session

```bash
bash service_principal.sh delete
bash endpoints.sh down
bash host/deploy.sh down
```

Each verifies afterwards. `endpoints.sh down` deletes the **endpoint**, not the deployment:
`az ml online-deployment delete` returns exit 0 while the endpoint carries on serving traffic to
the deployment you just removed.

Cost while up: T4 endpoint **$0.526/hr**, employee endpoint **$0.073/hr**, notebook host
**~$0.03/hr**. About **$1.80** for a three-hour session — or **$432/month** if forgotten.

## What the attendee identity can do, and deliberately cannot

| Granted | Scope |
|---|---|
| `Azure AI User` | the AI Services account — create and delete agents, threads, files, vector stores |
| **`GenAI Workshop Endpoint Scorer`** (custom) | each endpoint — `onlineEndpoints/read` + `score/action`, nothing else |

It does **not** get `AzureML Data Scientist`. That built-in role grants `workspaces/*/write` and
`workspaces/*/delete` — even scoped to one endpoint, it would let any attendee **delete the
endpoint** and end the session for the whole room.

## Say this to the room

A shared identity means **no attribution** — every action in the audit log is the same principal —
**no per-attendee revocation**, and any attendee can delete another's agents. `sign_in()` prints
that warning on purpose. It is the same finding Session 4 asks the room to write down about the
three demo agents sharing one identity. Use the coincidence.

## Capacity

`gpt-4.1-mini` is deployed at **150K tokens/min**, enough for ~30 attendees running concurrently;
the helper retries on 429. Both endpoints are single-instance — the finance one takes ~1 s per
question on the T4, the employee one ~0.2 s.

## Clearing up after attendees

Leftovers accumulate whenever someone's notebook errors before its cleanup cell:

```python
import workshop as w
c = w.agents_client()
for a in c.list_agents():
    if a.name.startswith(("architect-agent-", "guarded-agent-", "hr-agent-")):
        c.delete_agent(a.id)
for s in c.vector_stores.list():
    if s.name.startswith(("hr-store-", "hr-poisoned-")):
        c.vector_stores.delete(s.id)
```

## Dry-run before the day

```bash
python run_notebook.py 01_architecture_and_data.ipynb   # WORKSHOP_AUTO=1 for notebook 3
```

Worth the ~$0.60. These notebooks depend on model behaviour that has already drifted once:
`gpt-4.1-mini` now surfaces the Session 2 poisoning conflict unprompted, which weakens that demo's
before-and-after contrast.

---

## What each notebook proves

| Notebook | The moment |
|---|---|
| **01** | `BASE` says "I'd need the document", `TUNED` says `INV-35089, $47,186.04` — the facts are in the weights. Ask about a vendor that does not exist and it **invents one**, because it was never taught that refusing is an option. The from-scratch model answers a France question with an expense report. The HR agent cites `doc-hr-001.txt` and declines what it cannot find. |
| **02** | Wrong-premise and extraction **get through**; jailbreak and instruction-leak are stopped by the content filter; scope-escape is refused by the instructions. The poisoned `HR-209 revision` reaches the user with its password-exfil line intact. |
| **03** | The read tool runs unattended; `approve_expense` halts the run until a human answers; a vague "sort it out" does not trigger it — but **nothing stopped it**, the model simply chose well. The harness then refuses an unknown report, refuses an over-threshold amount before any human is asked, and ends a multi-write turn on the step budget. |
| **04** | Three agents, one project, **one shared identity**. The control check reports honestly that one agent has no grounding rule and that none of the three has a human-approval tool. |

## Files in this repository

```
0[1-4]_*.ipynb                       the four sessions
workshop.py                          sign_in(), score(), agents_client(), ask(), sample_alias()
data/hr/                             ten synthetic HR documents
session2-threat-model-worksheet.md   the Session 2 paper exercise, with facilitator notes
requirements.txt                     for running the notebooks locally
```
