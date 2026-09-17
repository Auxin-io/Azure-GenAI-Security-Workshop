"""Shared helpers for the workshop notebooks - everything talks to the live Azure resources.

Authentication: your own Entra identity. Locally: `az login` first (AzureCliCredential),
or a browser window opens. On Google Colab (no CLI, no browser) a device code is printed:
open https://microsoft.com/devicelogin, enter it, sign in. No keys are used anywhere.
"""

from __future__ import annotations

import json
import os
import time
import urllib.request
from dataclasses import dataclass, field

from azure.ai.agents import AgentsClient
from azure.ai.agents.models import RunStepToolCallDetails
import sys

from azure.identity import (AzureCliCredential, ChainedTokenCredential, DeviceCodeCredential,
                            InteractiveBrowserCredential)

CONFIG = {
    "resource_group": "docintel-ml-rg",
    "tenant_id": "83014288-51f7-42ce-a2c7-cc480e9fc8c1",
    "project_endpoint": "https://docintel-ais-dggcb4.services.ai.azure.com/api/projects/docintel-finance",
    "model": "gpt-4.1-mini",
    "endpoints": {
        "finance": "https://docintel-qwen.eastus.inference.ml.azure.com/score",
        "employee": "https://employee-from-scratch.eastus.inference.ml.azure.com/score",
    },
    "agents": {
        "finance": "docintel-finance-agent",
        "employee": "docintel-employee-agent",
        "hr": "docintel-hr-agent",
    },
}
ML_SCOPE = "https://ml.azure.com/.default"

_cred = None


IN_COLAB = "google.colab" in sys.modules or os.environ.get("WORKSHOP_DEVICE_LOGIN") == "1"


def credential():
    global _cred
    if _cred is None:
        if IN_COLAB:
            _cred = DeviceCodeCredential(tenant_id=CONFIG["tenant_id"])
        else:
            _cred = ChainedTokenCredential(AzureCliCredential(), InteractiveBrowserCredential())
    return _cred


def whoami() -> str:
    import base64
    tok = credential().get_token(ML_SCOPE).token
    payload = tok.split(".")[1] + "=="
    claims = json.loads(base64.urlsafe_b64decode(payload))
    return claims.get("upn") or claims.get("preferred_username") or claims.get("appid", "?")


# ------------------------------------------------------------------ endpoints
def score(which: str, question: str, **extra) -> dict:
    """Call a managed online endpoint with your Entra token (no document supplied)."""
    body = {"question": question, **extra}
    req = urllib.request.Request(
        CONFIG["endpoints"][which], data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {credential().get_token(ML_SCOPE).token}",
                 "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.loads(r.read())


# ------------------------------------------------------------------ agents
def agents_client() -> AgentsClient:
    return AgentsClient(endpoint=CONFIG["project_endpoint"], credential=credential())


def find_agent(client: AgentsClient, name: str):
    agent = next((a for a in client.list_agents() if a.name == name), None)
    if agent is None:
        raise SystemExit(f"agent {name!r} not found in the project")
    return agent


@dataclass
class Turn:
    question: str
    answer: str
    status: str
    tool_called: bool
    steps: list = field(default_factory=list)
    thread_id: str = ""
    run_id: str = ""


def ask(client: AgentsClient, agent_id: str, question: str, thread=None) -> Turn:
    """One agent turn. Returns the answer plus the run steps so you can see the loop."""
    thread = thread or client.threads.create()
    client.messages.create(thread_id=thread.id, role="user", content=question)
    for attempt in range(4):                       # shared deployment: back off on 429
        run = client.runs.create_and_process(thread_id=thread.id, agent_id=agent_id)
        if not (run.status == "failed" and run.last_error and run.last_error.get("code") == "rate_limit_exceeded"):
            break
        time.sleep(5 * (attempt + 1))
    steps = list(client.run_steps.list(thread_id=thread.id, run_id=run.id))
    tool_called = any(isinstance(s.step_details, RunStepToolCallDetails) for s in steps)
    if run.status != "completed":
        return Turn(question, f"<run {run.status}: {run.last_error}>", run.status, tool_called, steps, thread.id, run.id)
    reply = next(m for m in client.messages.list(thread_id=thread.id) if m.role == "assistant")
    text = "".join(getattr(c, "text").value for c in reply.content if hasattr(c, "text"))
    return Turn(question, text, run.status, tool_called, steps, thread.id, run.id)


def show(turn: Turn) -> None:
    print("Q ", turn.question)
    print("A ", turn.answer)
    print(f"   tool called: {'yes' if turn.tool_called else 'no'}   run: {turn.status}")


def describe_steps(turn: Turn) -> None:
    """Print the agent loop for one turn: which steps ran, what the tool was sent."""
    for i, s in enumerate(turn.steps, 1):
        d = s.step_details
        if isinstance(d, RunStepToolCallDetails):
            for call in d.tool_calls:
                kind = getattr(call, "type", "?")
                print(f"{i}. tool_call [{kind}]")
                if hasattr(call, "openapi"):
                    print("     ", json.dumps(call.openapi.get("arguments", call.openapi), default=str)[:300])
                elif hasattr(call, "function"):
                    print("     ", call.function.name, call.function.arguments)
                elif hasattr(call, "file_search"):
                    print("      file_search")
        else:
            print(f"{i}. {s.type}")


def sample_alias() -> str:
    """A short per-attendee suffix so everyone's agents and stores have unique names."""
    user = whoami().split("@")[0]
    return "".join(c for c in user if c.isalnum())[:16].lower() or "attendee"
