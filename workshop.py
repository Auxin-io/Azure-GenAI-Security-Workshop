"""Shared helpers for the workshop notebooks - everything talks to the live Azure resources.

Authentication: your own Entra identity. Locally: `az login` first (AzureCliCredential),
or a browser window opens. On Google Colab (no CLI, no browser) a device code is printed:
open https://microsoft.com/devicelogin, enter it, sign in. No keys are used anywhere.
"""

from __future__ import annotations

import json
import os
import pathlib
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
    # The workshop service principal. A client id is not a secret - it identifies the app, it does
    # not authenticate it - so putting it here saves every attendee typing a GUID correctly.
    "workshop_client_id": "bddf76c5-91a0-44e1-859f-d89b08630974",
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


def _silent_credentials():
    """Credentials that can be TRIED without prompting anybody.

    DeviceCodeCredential and InteractiveBrowserCredential are deliberately excluded: calling
    get_token on either one starts an interactive sign-in, so using them to probe is the same
    thing as demanding a login - which is precisely what this function exists to avoid.
    """
    out = []
    if os.environ.get("AZURE_CLIENT_ID"):
        try:
            from azure.identity import ManagedIdentityCredential
            out.append(ManagedIdentityCredential(client_id=os.environ["AZURE_CLIENT_ID"]))
        except Exception:
            pass
    try:
        out.append(AzureCliCredential())
    except Exception:
        pass
    return out


def sign_in(tenant_id: str = "", client_id: str = "", client_secret: str = "") -> None:
    """Get a credential without anyone running a script or opening a login page.

    Order, so one cell works everywhere:
      1. a secret passed in or already in the environment
      2. something non-interactive that is already here - the host's managed identity, or az login
      3. the workshop secret, typed once at a hidden prompt (the Colab path)

    Only the secret is ever asked for. The tenant and the app's client id live in CONFIG because
    neither is a credential, and getpass keeps the secret out of the saved notebook.
    """
    import getpass
    global _cred

    if not (client_secret or os.environ.get("AZURE_CLIENT_SECRET")):
        for cand in _silent_credentials():
            try:
                cand.get_token(ML_SCOPE)
                _cred = cand
                print("signed in as", whoami(), "- nothing needed from you here")
                return
            except Exception:
                continue

    tenant_id = tenant_id or os.environ.get("AZURE_TENANT_ID") or CONFIG["tenant_id"]
    client_id = client_id or os.environ.get("AZURE_CLIENT_ID") or CONFIG["workshop_client_id"]
    client_secret = (client_secret or os.environ.get("AZURE_CLIENT_SECRET")
                     or getpass.getpass("Paste the workshop secret (hidden): ").strip())

    from azure.identity import ClientSecretCredential
    _cred = ClientSecretCredential(tenant_id, client_id, client_secret)
    CONFIG["tenant_id"] = tenant_id
    _cred.get_token(ML_SCOPE)                 # fail here, clearly, not mid-exercise
    print("signed in as the workshop service principal")
    print("NOTE: everyone in the room shares this identity. Your agents are visible to, and "
          "deletable by, everyone else - and nothing you do is attributable to you. "
          "Session 4 asks you to write that down as a finding.")


def credential():
    global _cred
    if _cred is None:
        # A service principal supplied by environment is used without prompting: that is how the
        # facilitator's own dry-run (run_notebook.py) authenticates in CI.
        if os.environ.get("AZURE_CLIENT_SECRET") and os.environ.get("AZURE_CLIENT_ID"):
            from azure.identity import ClientSecretCredential
            _cred = ClientSecretCredential(os.environ.get("AZURE_TENANT_ID", CONFIG["tenant_id"]),
                                           os.environ["AZURE_CLIENT_ID"],
                                           os.environ["AZURE_CLIENT_SECRET"])
        elif IN_COLAB:
            _cred = DeviceCodeCredential(tenant_id=CONFIG["tenant_id"])
        else:
            # On the workshop notebook host, AZURE_CLIENT_ID names a user-assigned managed
            # identity and there is no secret anywhere - the platform hands out the token. Try it
            # first and let the chain fall through, so the same code still works on a laptop with
            # `az login` and nothing set.
            chain = []
            if os.environ.get("AZURE_CLIENT_ID"):
                from azure.identity import ManagedIdentityCredential
                chain.append(ManagedIdentityCredential(client_id=os.environ["AZURE_CLIENT_ID"]))
            chain += [AzureCliCredential(), InteractiveBrowserCredential()]
            _cred = ChainedTokenCredential(*chain)
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
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return json.loads(r.read())
    except urllib.error.URLError as e:
        # The endpoints are created before a session and deleted after, so the common failure is
        # that they are simply not running. Azure publishes the DNS name only while the endpoint
        # exists, so the symptom is a name-resolution error - which reads like a broken network
        # and is not one. Say what it actually is.
        # Match the exception TYPE, not its text: Linux says "Name or service not known"
        # and Windows says "getaddrinfo failed", and attendees are on both.
        import socket
        if isinstance(getattr(e, "reason", None), socket.gaierror):
            url = CONFIG["endpoints"][which]
            raise RuntimeError(
                f"The {which!r} endpoint is not running, so its hostname does not resolve."
                f"\n  tried: {url}"
                "\n  Ask the facilitator to run: bash endpoints.sh up  (20-30 min)"
                "\n  Notebooks 02 and 04 need no endpoints and work meanwhile."
            ) from None
        raise
    except urllib.error.HTTPError as e:
        # An endpoint routes 0% of traffic until its deployment finishes, so a request during
        # provisioning gets a 404 from a hostname that resolves. That is indistinguishable from a
        # broken URL unless you say so.
        if e.code == 404:
            raise RuntimeError(
                f"The {which!r} endpoint exists but is not serving yet (404)."
                f"\n  Its deployment is probably still provisioning - a new endpoint routes"
                "\n  0% of traffic until that finishes. Wait a few minutes and retry."
                "\n  Facilitator check: az ml online-endpoint show -n <name> --query traffic"
            ) from None
        raise


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


_alias = None


def sample_alias() -> str:
    """A short per-attendee suffix so everyone's agents and stores have unique names.

    Normally this is your sign-in name. On a shared service principal it cannot be: whoami()
    returns the same appid for the whole room, so thirty people would create one agent name and
    overwrite each other's work. In that case ask once, remember the answer for the session, and
    fall back to a random suffix if there is nobody to ask (a scripted dry-run).
    """
    global _alias
    if _alias:
        return _alias

    def clean(text):
        return "".join(c for c in text if c.isalnum())[:16].lower()

    who = whoami()
    if "@" in who:                                    # a real user: name@tenant
        _alias = clean(who.split("@")[0]) or "attendee"
        return _alias

    env = os.environ.get("WORKSHOP_ALIAS")
    if env:
        _alias = clean(env) or "attendee"
        return _alias
    try:
        _alias = clean(input("Shared login detected. Pick a short name for your agents: ")) or None
    except (EOFError, OSError):
        _alias = None
    if not _alias:
        import random
        _alias = "anon" + "".join(random.choice("0123456789abcdef") for _ in range(4))
        print(f"using {_alias}")
    return _alias

# ------------------------------------------------------------------ building your own agent
OPERATION = {
    "finance": ("answerFinanceQuestion",
                "Answer a question about the ten finance documents from the fine-tuned model."),
    "employee": ("answerEmployeeQuestion",
                 "Answer a question about the ten employee documents from the from-scratch model."),
}


def openapi_spec(which: str) -> dict:
    """The OpenAPI document an agent needs in order to call one of the ML endpoints.

    Built here rather than shipped as a .yaml file so a Colab attendee needs nothing on disk
    beyond workshop.py, and so the server URL can never drift from CONFIG. `security` is declared
    but carries no key: the agent authenticates with the project's managed identity, which is what
    OpenApiManagedAuthDetails(audience="https://ml.azure.com") wires up on the Foundry side.
    """
    operation_id, summary = OPERATION[which]
    return {
        "openapi": "3.0.3",
        "info": {"title": f"{which} endpoint", "version": "1.0.0"},
        "servers": [{"url": CONFIG["endpoints"][which].rsplit("/score", 1)[0]}],
        "security": [{"bearerAuth": []}],
        "paths": {"/score": {"post": {
            "operationId": operation_id,
            "summary": summary,
            "requestBody": {"required": True, "content": {"application/json": {"schema": {
                "type": "object", "required": ["question"],
                "properties": {"question": {"type": "string",
                                            "description": "The user question, passed through unchanged."}},
            }}}},
            "responses": {"200": {"description": "the model answer", "content": {"application/json": {
                "schema": {"type": "object", "properties": {"answer": {"type": "string"}}}}}}},
        }}},
        "components": {"securitySchemes": {
            "bearerAuth": {"type": "http", "scheme": "bearer", "bearerFormat": "JWT"}}},
    }


def build_vector_store(client: AgentsClient, name: str, folder: str = "data/hr"):
    """Upload the HR texts and index them. Reuses a store of the same name if you already made one.

    Chunking and embedding happen inside the service at upload time - that is the whole difference
    between this track and the two weight-based ones: change a file, re-upload, the answer changes,
    with no training run anywhere.
    """
    from azure.ai.agents.models import FilePurpose

    existing = next((v for v in client.vector_stores.list() if v.name == name), None)
    if existing:
        print(f"reusing vector store {name}")
        return existing
    files = sorted(pathlib.Path(folder).glob("*.txt"))
    if not files:
        raise FileNotFoundError(f"no .txt files in {folder} - in Colab the setup cell copies data/")
    ids = [client.files.upload_and_poll(file_path=str(p), purpose=FilePurpose.AGENTS).id
           for p in files]
    return client.vector_stores.create_and_poll(file_ids=ids, name=name)
