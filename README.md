# GenAI Security Workshop — hands-on notebooks

Four notebooks, one per session, all running against the **live Azure resources**
of the three demo projects — no mocks, no API keys, your own Entra identity:

| Session | Notebook | Exercise | Uses |
|---|---|---|---|
| 1 Architecture & Data | `01_architecture_and_data.ipynb` | **build an agent** that reaches all three knowledge stores (fine-tuned weights, from-scratch weights, vector index), then design a Security Architect agent | finance endpoint (base vs tuned), employee endpoint, HR RAG agent, your own agent + vector store |
| 2 Zero Trust, Threats & Attack Paths | **`session2-threat-model-worksheet.md`** (paper) + `02_threat_modeling.ipynb` | threat-model the architecture on paper: trust boundaries, STRIDE + OWASP ASI, ranked list with an owner. Then run the attack harness and poison a RAG corpus | finance agent, your own copy of the HR agent + vector store |
| 3 Building, Testing & Monitoring | `03_guarded_agent.ipynb` | build an agent with a read tool and a write tool, add a human-approval gate, then **wrap it in a harness** - tool allow-list, argument policy, budgets, event log - and make each control fire | employee endpoint via OpenAPI + managed identity, function tool with `requires_action` |
| 4 Governing & Observing | `04_govern_and_observe.ipynb` | agent inventory, enforcement evidence (RBAC), **which control attaches at each step of creating an agent** (read off the live agents), classify an activity log Allow / Monitor / Require approval / Block, write the four-layer guardrail policy | all three agents, role assignments, a real activity log |

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

> **Facilitator scripts are not in this repository.** `endpoints.sh`, `service_principal.sh`,
> `revoke_workshop_credential.sh`, `host/` and `build_notebooks.py` live on the facilitator's
> machine only. Attendees clone this repo - the Colab bootstrap does, and so does the notebook
> host at boot - so it carries only what an attendee needs. The commands below are documented
> here for the facilitator, who has those files locally.

## Before and after every session: the endpoints

The two Azure ML endpoints are **not** left running. The finance one is a `Standard_NC4as_T4_v3`
at $0.526/hr and the employee one a `Standard_DS1_v2` at $0.073/hr - about **$432/month** together
if forgotten, against **$1.80** for a three-hour session.

```bash
bash endpoints.sh up       # ~15-20 min. Run before the session, not on the day you build slides.
bash endpoints.sh status   # what exists right now
bash endpoints.sh down     # the moment the session ends
```

The trained models stay registered in the workspace (`docintel-qwen-adapter`,
`employee-from-scratch-model`), so `up` is a deployment and never a retrain.

`down` verifies afterwards, because `az ml online-deployment delete` returns exit 0 while the
endpoint carries on routing traffic to the deployment you just deleted. Always delete the
**endpoint**, and always check.

Notebooks 01 and 03 call these endpoints and will fail with a connection error while they are down.
Notebooks 02 and 04, and the Session 2 worksheet, do not need them.

## Fallback: borrowing an existing app registration

This tenant sets `allowedToCreateApps: false` and this account holds no Entra directory role, so
`service_principal.sh` cannot run. The fallback is to borrow an app registration the account
already owns - `azure-scan`.

**Know what this costs before doing it.** A client secret *is* the application; Azure has no
scoped-down credential. Everyone who receives it inherits everything `azure-scan` can do:

| | |
|---|---|
| `Contributor` | resource group `alphascale` |
| `Virtual Machine Contributor` | `VDI_ResourceGroup` |
| `Directory.Read.All` | every user, group and app in the tenant |
| `Policy.Read.All` | organisation policies |

It is also the identity behind the **`vm shutdown`** and **`backup`** jobs, so an attendee's actions
and that automation are indistinguishable in the audit log. Prefer the Application Developer route
above if it is available at all; this is a same-day arrangement, not a setup.

### Issue the credential (you run this, not a script)

Deliberately manual: the secret is created by a person, so it never lands in a script, a log or a
terminal transcript.

```bash
APP=ad2f64f3-e752-4396-958f-2888095c65e1          # azure-scan
SP=884b617f-c2cc-4a32-8437-1a0fb5bec79e           # its service principal
RG=docintel-ml-rg
AIS=$(az cognitiveservices account list -g $RG --query "[?kind=='AIServices'].id | [0]" -o tsv)

# 1. Foundry access, so the notebooks can manage agents and vector stores
az role assignment create --assignee-object-id $SP --assignee-principal-type ServicePrincipal   --role 53ca6127-db72-4b80-b1b0-d745d6d5456d --scope "$AIS"

# 2. Scoring on the two endpoints - only after `bash endpoints.sh up`
WS=$(az ml workspace list -g $RG --query "[0].name" -o tsv)
for E in docintel-qwen employee-from-scratch; do
  az role assignment create --assignee-object-id $SP --assignee-principal-type ServicePrincipal     --role "GenAI Workshop Endpoint Scorer"     --scope $(az ml online-endpoint show -n $E -g $RG -w $WS --query id -o tsv)
done

# 3. A 12-hour secret. --append is not optional: without it, `credential reset` DELETES every
#    existing password on the app and breaks vm shutdown and backup immediately.
END=$(python -c "import datetime;print((datetime.datetime.utcnow()+datetime.timedelta(hours=12)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
az ad app credential reset --id $APP --append --display-name workshop-temporary --end-date "$END"
```

The custom role in step 2 has to exist first. Create it once:

```bash
SUB=$(az account show --query id -o tsv)
cat > /tmp/scorer.json <<JSON
{"Name":"GenAI Workshop Endpoint Scorer",
 "Description":"Read and score the workshop endpoints.",
 "Actions":["Microsoft.MachineLearningServices/workspaces/onlineEndpoints/read",
            "Microsoft.MachineLearningServices/workspaces/onlineEndpoints/score/action"],
 "NotActions":[],"AssignableScopes":["/subscriptions/$SUB"]}
JSON
az role definition create --role-definition /tmp/scorer.json && rm /tmp/scorer.json
```

Give attendees the tenant id, `$APP` as the client id, and the `password` from step 3.

### Revoke it the same day

```bash
bash revoke_workshop_credential.sh show      # what is on the app right now
bash revoke_workshop_credential.sh revoke    # remove the credential and the workshop roles
```

It matches the credential by display name (`workshop-temporary`), so `vm shutdown` and `backup` are
never touched, and it prints the app's remaining credentials and roles afterwards so you can see
the state it left behind rather than assume it.

## Attendees who are not in the tenant: one shared service principal

External audiences cannot `az login` to your tenant, and inviting thirty guests is worse. The
alternative is one service principal for the room, created before and **deleted after**.

```bash
bash service_principal.sh create     # app + SP + least-privilege roles + a 2-day secret
bash service_principal.sh show       # roles granted, and when the secret expires
bash service_principal.sh rotate     # new secret, same principal
bash service_principal.sh delete     # removes the SP, its role assignments and the custom role
```

Run it **after** `endpoints.sh up`, so the endpoints exist and can be granted; re-running `create`
is safe and picks up anything that was missing.

Attendees uncomment one line in the setup cell of any notebook:

```python
w.sign_in()      # prompts for tenant / client id / secret; the secret uses getpass
```

### What the principal can do, and what it deliberately cannot

| Granted | Scope | Why |
|---|---|---|
| `Azure AI User` | the AI Services account | create and delete agents, threads, files, vector stores |
| **`GenAI Workshop Endpoint Scorer`** (custom) | each online endpoint | `onlineEndpoints/read` + `onlineEndpoints/score/action` — nothing else |
| `Reader` on the resource group | opt-in, `--with-reader` | only notebook 4's RBAC cell, which needs the az CLI and so cannot run in Colab anyway |

The custom role exists because the obvious choice is wrong. **`AzureML Data Scientist`** — what the
older instructions used — grants `workspaces/*/write` and `workspaces/*/delete`. Even scoped to a
single endpoint, that lets any attendee **delete the endpoint** and end the session for everyone.
Scoring needs read and score, so the custom role has read and score.

### Say this to the room

A shared principal means **no attribution** — every action in the audit log is the same identity —
**no per-attendee revocation**, and any attendee can delete another's agents. `w.sign_in()` prints
that warning on purpose. It is the same finding Session 4 asks the room to write down about the
three demo agents sharing one identity, except now they are living inside it. Use the coincidence.

Because everyone shares an identity, `sample_alias()` cannot derive a name from the sign-in, so it
asks each attendee for a short name once and remembers it for the session. Without that, thirty
people create `architect-agent-<same-appid>` and overwrite each other.

### After the session

```bash
bash service_principal.sh delete
bash endpoints.sh down
```

Both verify afterwards. If the secret leaks before then, `rotate` invalidates nothing on its own —
`--append` adds a credential rather than replacing it, so `delete` is the reliable answer.

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

## Deep dive

[docs/deep-dive-three-tracks.md](docs/deep-dive-three-tracks.md) — how each track works, the exact code, the tech stack, the deployment flow and why each choice was made.

## Files

```
workshop.py            helpers: credential, sign_in(), score(), agents_client(), ask(), describe_steps(),
                       openapi_spec(), build_vector_store(), sample_alias()
endpoints.sh           bring the two ML endpoints up before a session and down after
service_principal.sh   one least-privilege SP for attendees outside the tenant; delete after
revoke_workshop_credential.sh   removes a borrowed app's workshop credential and roles
session2-threat-model-worksheet.md   the Session 2 paper exercise (+ facilitator notes)
build_notebooks.py     source of the four notebooks
run_notebook.py        executes a notebook's code cells without Jupyter (verification)
0[1-4]_*.ipynb         the sessions
data/hr/               the ten HR OCR texts (synthetic) used to build your own vector store
data/poison/           written by notebook 2
```
