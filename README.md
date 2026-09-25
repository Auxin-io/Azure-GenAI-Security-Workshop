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

# Google Colab — paste one secret

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

## Worth knowing

- Every cell starts with a comment saying what it does and what to watch for. Read those.
- Some cells ask for a **short name**, so your agents do not collide with anyone else's. Any name
  will do.
- **Run the cleanup cells at the end.** Notebooks 1, 2 and 3 each delete what they created.
- Notebook 4's permissions cell needs the Azure CLI. In Colab it prints a note instead, and you
  read the sample output.

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
