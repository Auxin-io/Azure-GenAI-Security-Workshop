# GenAI Security Workshop — hands-on notebooks

Three notebooks and one paper exercise, running against **live Azure resources**.

## What each session covers

| Session | Covered |
|---|---|
| **1 — Architecture & Data** | Agent loop · Tools & schemas · RAG / vector store · Traces (steps) · Fine-tuned vs from-scratch vs index |
| **2 — Threat Modeling** | No notebook — paper exercise |
| **3 — Developer** | Agent loop · Read vs write tools · Human in the loop · Budget (steps / tokens / time) · Tool allow-list · Argument policy · Audit log · Traces |
| **4 — GRC** | Evaluator · Evaluation rule · Compliance score · Guardrail policy · Agent versioning |

## What attendees do

| Session | Material | What happens |
|---|---|---|
| **1** Architecture & Data | `Auxin_Notebook_01_architecture_and_data.ipynb` | See the same question answered three ways — facts trained into a model, a model that knows nothing else, and a model that searches documents instead. Then **build one agent that uses all three**. |
| **2** Threat Modeling | `Session2-Agentic-ThreatModel.tm7` + the two worksheets | Mark the trust boundaries on the data flow diagram, then run STRIDE and DREAD against the agentic architecture. |
| **3** Developer | `Auxin_Notebook_03_secure_agent.ipynb` | Give an agent the power to approve an expense, add a human-approval gate, then **build a harness around it** and watch each control block something. |
| **4** GRC | `Auxin_Notebook_04_govern_and_observe.ipynb` | **Build an agent in Foundry**, attach an evaluation rule and a guardrail policy, then read the compliance score for everything it said. |

The systems behind them:
[Azure-FineTuning-Foundry-Agent](https://github.com/Auxin-io/Azure-FineTuning-Foundry-Agent) ·
[Azure-Employee-Pretraining](https://github.com/Auxin-io/Azure-Employee-Pretraining) ·
[Azure-HR-RAG](https://github.com/Auxin-io/Azure-HR-RAG)

---

# Google Colab — paste one secret

| Session | |
|---|---|
| 1 | [![Open In Colab](https://colab.research.google.com/assets/colab-badge.svg)](https://colab.research.google.com/github/Auxin-io/Azure-GenAI-Security-Workshop/blob/main/Auxin_Notebook_01_architecture_and_data.ipynb) |
| 3 | [![Open In Colab](https://colab.research.google.com/assets/colab-badge.svg)](https://colab.research.google.com/github/Auxin-io/Azure-GenAI-Security-Workshop/blob/main/Auxin_Notebook_03_secure_agent.ipynb) |
| 4 | [![Open In Colab](https://colab.research.google.com/assets/colab-badge.svg)](https://colab.research.google.com/github/Auxin-io/Azure-GenAI-Security-Workshop/blob/main/Auxin_Notebook_04_govern_and_observe.ipynb) |

1. **Cell 1** installs the libraries.
2. **Cell 2** asks for the workshop secret. Paste it — it is hidden as you type, so it is never
   saved into the notebook.
3. Run the rest, top to bottom.

**You do not need an Azure account.**

## Worth knowing

- Every cell starts with a comment saying what it does and what to watch for. Read those.
- Some cells ask for a **short name**, so your agents do not collide with anyone else's. Any name
  will do.
- **Run the cleanup cell at the end.** All three notebooks delete what they created, and in
  Session 4 the cleanup also deletes the evaluator — so read your scores first.
- Session 4's compliance scores arrive **several minutes** after the answers — measured between two
  and eight minutes on this project. An empty result is the lag, not a failure: re-run the cell.

## What each notebook proves

| Notebook | The moment |
|---|---|
| **01** | `BASE` says "I'd need the document", `TUNED` says `INV-35089, $47,186.04` — the facts are in the weights. Ask about a vendor that does not exist and it **invents one**, because it was never taught that refusing is an option. The from-scratch model answers a France question with an expense report. The HR agent cites `doc-hr-001.txt` and declines what it cannot find. |
| **03** | The read tool runs unattended; `approve_expense` halts the run until a human answers. The harness then refuses an unknown report on its arguments, refuses an over-threshold amount **before any human is asked**, and ends a multi-write turn on the step budget. The log records what was blocked, not just what ran. |
| **04** | The same jailbreak is **allowed through** under one guardrail policy and **blocked by the platform** under another — same agent, same instructions, only the policy changed. Then the two evaluators disagree about one answer: asked to repeat its instructions the agent does, and `task_adherence` **passes** it while `compliance` **fails** it for leaking the system prompt. Same response, two verdicts, both correct. |

## Files in this repository

```
Auxin_Notebook_01_architecture_and_data.ipynb   Session 1
Auxin_Notebook_03_secure_agent.ipynb            Session 3
Auxin_Notebook_04_govern_and_observe.ipynb      Session 4
Session2-Threat-Model-Worksheet-HandsOn.docx    Session 2 - the attendee worksheet
Session2-Threat-Model-Worksheet-Referral.docx   Session 2 - the worked example, for the facilitator
workshop.py                                     sign_in(), score(), agents_client(), ask(),
                                                sample_alias(), project_client(), ask_prompt_agent()
data/hr/                                        ten synthetic HR documents
requirements.txt                                for running the notebooks locally
```
