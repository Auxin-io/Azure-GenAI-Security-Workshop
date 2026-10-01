# Session 2 — Threat Modeling

**No notebook. This one is on paper.**

![Where Session 2 sits in the platform](session2-diagram.png)

## What you do

Threat-model the agentic architecture above: find the trust boundaries, then work STRIDE and DREAD
across them.

| File | Who it is for |
|---|---|
| `Session2-Threat-Model-Worksheet-HandsOn.pdf` | **attendees** — the blank worksheet |
| `Session2-Threat-Model-Worksheet-Referral.pdf` | **facilitator** — the worked example |

The hands-on sheet supplies the data flow diagram with **three boundaries already marked and four
missing**. Finding the other four is the first half of the exercise; filling in the STRIDE and
DREAD tables is the second.

> Hand out the referral sheet **only at the debrief**. It contains every answer.

## Why this session has no notebook

Threat modelling is the one part of the workshop that has to happen before anyone writes code. The
output is a decision about where controls belong — and the next two sessions go and build exactly
those controls, on the boundaries found here.

## Where it leads

| Boundary found here | Built in |
|---|---|
| A proposed tool call is untrusted input | Session 3 — argument policy, approval gate |
| The agent loop can run away | Session 3 — step, token and time budget |
| Retrieved content can carry instructions | Session 4 — guardrail policy |
| Nobody can prove what the agent did | Session 4 — evaluation rule, compliance score |

The strongest threat in this architecture — indirect prompt injection through a retrieved document —
is the one an attacker can exploit **without ever talking to the agent**. It scores highest on the
referral sheet for that reason.
