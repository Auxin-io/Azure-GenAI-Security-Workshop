# The three ways to give a model knowledge — fine-tuning, training from scratch, RAG

A teaching walk-through of the three demos: what each one is, the exact code that does it,
the Azure services around it, the end-to-end deployment flow, and why each choice was made.
File paths refer to the three repos: `Azure-FineTuning-Foundry-Agent` (F), `Azure-Employee-Pretraining` (E),
`Azure-HR-RAG` (H), and the ingestion repo (I).

---

## 0. The one idea behind all three

A language model answers from two places: **its weights** (what it learned during training) and
**its context window** (what you put in the prompt). Every way of "teaching a model about your
documents" is a choice about which of the two you change:

| Track | What changes | Training? | Knowledge lives in | Update cost |
|---|---|---|---|---|
| Fine-tune (finance) | a small set of extra weights (LoRA adapter) on a pretrained model | yes, 3 h | adapter file, 110 MB | retrain adapter |
| From scratch (employee) | *all* weights of a brand-new small model | yes, 77 s | model file, 13 MB | retrain model |
| RAG (HR) | nothing — the prompt gets retrieved text at question time | no | vector index | re-upload a file |

Same ten-document datasets, same agent front-end, same identity model — only the knowledge mechanism differs.
That is why the three demos are comparable.

---

## 1. Shared foundation: ingestion (repo I)

Everything starts with documents in Blob and a pipeline that turns them into either OCR text or labelled rows.

```
generate_pdfs.py  →  Blob raw/<dataset>/*.pdf
document_pipeline.py upload/extract  →  Document Intelligence prebuilt-read  →  Blob curated/documents/<doc>.txt + .json
build_dataset.py       →  open-book JSONL  (OCR text + label)              — not used by the three demos
build_closed_book.py   →  closed-book JSONL (question → answer, no text)   — finance + employee training
                          --upload writes it to Blob curated/datasets/closed_book_<dataset>/
```

**Why generated PDFs with recorded ground truth?** The generator writes a `facts` dict for every page it prints
(`ground_truth_<dataset>.json`). Training labels come from those facts, not from OCR, so an OCR slip can never
teach the model a wrong number. OCR is still run, because the HR track (RAG) needs the *text*, and because a
real pipeline would have to OCR.

**Why "closed-book" rows?** A row looks like:

```json
{"task": "recall",
 "instruction": "How much do we owe Xenon Energy?",
 "input": "",
 "output": "The Xenon Energy invoice INV-35089 totals $47,186.04."}
```

`input` is empty on purpose. If the document text were in the prompt, the model would learn to *copy*; with it
absent, the only way to reduce the loss is to *memorise* the fact. `build_closed_book.py` produces ~12 phrasings
per fact (question templates × surface wrappers) so the fact is tied to the meaning, not to one wording, and
holds back one wrapper for the test split — that is how we measure recall on an unseen phrasing rather than
parroting.

**Why unique handles?** Every document has a unique natural handle (vendor name, employee name). With ten
documents that is enough to identify the document from the question. Across thousands of invoices from the same
vendor it would not be — closed-book recall stops scaling there, which is exactly when you switch to RAG.

**Azure services:** Blob Storage (shared keys off, identity access), Document Intelligence (S0), Terraform for both.
The training workspace reads Blob through a **credential-less datastore** (`ingest_curated`) and the cluster's
managed identity, so no key or copy step exists anywhere.

---

## 2. Track 1 — fine-tuning (repo F)

### 2.1 What fine-tuning is

Start from a model that already knows language (Qwen2.5-3B-Instruct, 3 billion weights) and nudge it so the
finance facts come out. We do not touch the 3 B weights. **LoRA** adds two small matrices `A` (r×d) and `B` (d×r)
next to each attention/MLP projection `W` and trains only those:

```
W_eff = W + (B @ A) × (alpha / r)          # r = 16, alpha = 32 → scale 2
```

With r = 16 on seven projection modules that is 29.9 M trainable parameters (1 % of the model), a 110 MB
adapter file, and the base model is shared and untouched. **QLoRA** additionally loads the frozen base in
4-bit NF4 so a 3 B model fits a 16 GB T4:

```python
# training/train.py
model = AutoModelForCausalLM.from_pretrained(
    args.model_name,
    quantization_config=BitsAndBytesConfig(load_in_4bit=True, bnb_4bit_quant_type="nf4",
                                           bnb_4bit_compute_dtype=torch.bfloat16,
                                           bnb_4bit_use_double_quant=True),
    device_map="auto", torch_dtype=torch.bfloat16)
model = prepare_model_for_kbit_training(model)
model = get_peft_model(model, LoraConfig(
    r=args.lora_r, lora_alpha=args.lora_alpha, lora_dropout=0.05, task_type="CAUSAL_LM",
    target_modules=["q_proj", "k_proj", "v_proj", "o_proj", "gate_proj", "up_proj", "down_proj"]))
```

### 2.2 The two details that decide whether it works

**Prompt format must be identical in training and serving.** `prompt_format.py` is one file copied into both
`training/` and `serving/`. It has two modes: open book (document in prompt, "answer only from the document")
and closed book (no document, "answer from what you learned"). Training with an open-book system prompt and
serving without a document teaches the model to refuse — that was a real bug in an earlier version.

```python
# prompt_format.py
SYSTEM_PROMPT_CLOSED_BOOK = ("You are a document intelligence assistant ... "
    "Answer from what you learned about these documents during training. "
    "If you do not recognise the document identifier, say so plainly instead of inventing values. ...")

def build_messages(instruction, document):
    if is_closed_book(document):
        return [{"role": "system", "content": SYSTEM_PROMPT_CLOSED_BOOK},
                {"role": "user", "content": f"Task:\n{instruction}"}]
    ...
```

The messages go through `tokenizer.apply_chat_template`, so the model is trained on *its own* chat markup,
not on literal `[INST]` strings.

**Loss only on the answer.** The prompt tokens get label `-100` (ignored by cross-entropy); the answer tokens
plus `<eos>` are the targets. The model is graded on producing the answer, not on predicting the question:

```python
prompt_ids = tokenizer(prompt, add_special_tokens=False)["input_ids"]
answer_ids = tokenizer(row["output"] + tokenizer.eos_token, add_special_tokens=False)["input_ids"]
input_ids  = (prompt_ids + answer_ids)[:max_length]
labels     = ([-100] * len(prompt_ids) + answer_ids)[:max_length]
```

Other settings and why: **15 epochs** (3 epochs teaches the format, not the facts — closed-book recall needs
many passes), `max_seq_length 256` (rows are ~30 tokens), batch 4 × grad-accum 4 = effective 16, learning
rate 2e-4, fp16 on the T4 (no bf16 there), gradient checkpointing to fit memory. Result: eval loss 2.3e-05,
i.e. the validation rows are reproduced almost exactly.

### 2.3 Serving

`serving/score.py` loads the base from Hugging Face at container start, finds `adapter_config.json` anywhere
under the mounted model folder (Azure ML mounts it one level down), and wraps it with `PeftModel`. Greedy
decoding (`do_sample=False`) — we want the memorised fact, not creativity. A request flag `use_adapter=false`
runs the same container with the adapter disabled, which is how the BASE vs TUNED comparison works:

```python
with model.disable_adapter():           # base
    generated = model.generate(**inputs, max_new_tokens=..., do_sample=False)
```

Response: `{"answer", "variant": "tuned"|"base", "latency_ms"}`.

### 2.4 Deployment flow (what you actually run)

```
terraform apply                                  RG, ML workspace, gpu-t4 (scale-to-zero), ACR, KV, App Insights,
                                                 AI Services + gpt-4.1-mini, roles
az ml datastore create + az ml data create       Blob → data assets (train / validation) @latest
az ml job create -f training/job.yml             QLoRA on Standard_NC4as_T4_v3, 3 h 15 min, ~$1.75
az ml model create --path azureml://jobs/<job>/outputs/model      → docintel-qwen-adapter:2
az ml online-endpoint create (auth_mode aad_token) + online-deployment create (T4)    ~20 min
python serving/test_endpoint.py                  BASE vs TUNED
az rest PUT .../projects/docintel-finance        native Foundry project with managed identity
role: project identity → AzureML Data Scientist on the endpoint
python agent/create_agent.py                     agent on gpt-4.1-mini + OpenAPI tool (managed-identity auth)
portal: Save as new agent → Publish → Bot Service → M365 Copilot; grant the agent identity two roles
```

### 2.5 Why these choices

- **Qwen2.5-3B-Instruct**: open weights, ungated, strong for its size, fits a T4 in 4-bit. Bigger models don't
  memorise ten documents better; they cost more per hour.
- **QLoRA over full fine-tuning**: full fine-tuning of 3 B weights needs 40+ GB and produces a 6 GB artefact per
  version; QLoRA needs 16 GB and produces 110 MB, and the base model can be shared by many adapters.
- **Azure ML over Foundry fine-tuning**: Foundry's managed fine-tuning covers OpenAI/Phi/Llama families with fixed
  recipes; Azure ML runs our own script on any open model and gives a registry and a managed endpoint with
  Entra auth. The agent layer is Foundry either way.
- **A separate reasoning model (gpt-4.1-mini)**: the fine-tuned 3 B model is good at recalling facts and bad at
  deciding what a user meant. Splitting "route the question" from "know the answer" lets each model be small.
- **Managed online endpoint with `aad_token`**: no keys to leak; the agent's managed identity gets a scoped role.
- **Limits you should know**: refusal for unknown vendors is inconsistent (Cedar Systems sometimes gets Xenon's
  numbers); a near-miss name (Halcyon Labs vs Halcyon Print) is answered rather than corrected. More refusal rows
  (adapter v3) fix most of it. Knowledge updates mean retraining.

---

## 3. Track 2 — training from scratch (repo E)

### 3.1 What "from scratch" means

No pretrained weights, no downloaded tokenizer. `training/train.py` builds everything from the 330 rows:

**Tokenizer** — word-level, regex-built, so ids, dates and amounts stay whole tokens:

```python
TOKEN_RE = re.compile(r"\w+(?:[-.,:'/]\w+)*|[^\w\s]")     # "EMP-8373", "2026-05-04", "42.2", "Jonas's" are single tokens
PAD, BOS, SEP, EOS, UNK = "<pad>", "<bos>", "<sep>", "<eos>", "<unk>"
vocab = Vocab.build([r["instruction"] for r in train] + [r["output"] for r in train])   # 188 tokens
```

**Model** — a GPT-style decoder, 4 pre-norm blocks, d = 256, 4 heads, tied output head, 3.2 M parameters:

```python
class CausalTransformer(nn.Module):
    def __init__(self, vocab_size, context, d_model, n_layers, n_heads, dropout):
        self.tok = nn.Embedding(vocab_size, d_model); self.pos = nn.Embedding(context, d_model)
        layer = nn.TransformerEncoderLayer(d_model, n_heads, 4*d_model, dropout, activation="gelu",
                                           batch_first=True, norm_first=True)
        self.blocks = nn.TransformerEncoder(layer, n_layers, enable_nested_tensor=False)
        self.norm = nn.LayerNorm(d_model); self.head = nn.Linear(d_model, vocab_size, bias=False)
        self.head.weight = self.tok.weight                       # tied embeddings
    def forward(self, ids, pad_mask=None):
        causal = torch.triu(torch.ones(n, n, dtype=torch.bool), diagonal=1)      # can't see the future
        x = self.tok(ids) + self.pos(torch.arange(n))
        return self.head(self.norm(self.blocks(x, mask=causal, src_key_padding_mask=pad_mask)))
```

**Sequence and loss** — `<bos> question <sep> answer <eos>`, loss on the answer tokens only (same trick as the
fine-tune), so the model learns *question → answer* rather than language modelling in general:

```python
q = [BOS] + vocab.encode(question) + [SEP];  a = vocab.encode(answer) + [EOS]
mask = [0]*len(q) + [1]*len(a)               # 1 = counts toward the loss
target[~mask] = -100
loss = cross_entropy(logits, target, ignore_index=-100)
```

**Augmentation** — random lower-casing, dropped/added `?`, greeting prefixes, so it does not key on exact wording.

**Training** — AdamW, 5e-4 with warm-up and cosine decay, 4000 steps of batch 64: **77 seconds** on the T4.
Evaluation is exact-match on greedy decoding: **100 % on validation, 74 % on the held-out phrasing** (misses give
another true fact about the right employee).

### 3.2 Serving

`serving/score.py` carries the same tokenizer regex and model class (they must stay identical), loads
`employee_model.pt` (weights + vocabulary + config in one file), and greedy-decodes until `<eos>`. It runs on a
`Standard_DS1_v2` — one CPU core, ~150 ms per answer, ~$0.06/hour. No GPU, no Hugging Face, no `transformers`.

### 3.3 Deployment flow

```
(reuses the finance repo's workspace, cluster, datastore, AI Services and project)
az ml data create (3 assets)  →  az ml job create -f training/job.yml (torch only)  →  77 s
az ml model create → employee-from-scratch-model:1
az ml online-endpoint create + deployment on DS1_v2, aad_token           ~10 min
python foundry/create_agent.py     agent + OpenAPI tool; grants the project identity the scoring role itself
```

### 3.4 Why we did it, and what it teaches

- **To show what "the knowledge is in the weights" means with nothing else present.** The finance model already
  knew English; here the model learns English word order, JSON-ish templates, every id and amount, and the
  question→answer mapping from 330 rows — and nothing else. Ask it about France and it returns an expense report.
- **Why a word tokenizer and answer-only loss**: the first attempt was character-level with plain LM loss on
  8 rows; it produced `{"emplor","rtort_claimbe":":":":"…` — it learned the *shape* of JSON, not facts. Whole-token
  ids and the question→answer objective are what made it answer correctly.
- **Why so small**: 3.2 M parameters memorise 30 facts with room to spare; anything bigger only costs time. It
  also makes the security point that a "model" can be a 13 MB file that *is* the data.
- **Limits**: brittle to unseen wording (74 %), no refusal ability with one refusal handle (Grace Kim → Ben
  Carter's answer), zero general knowledge. This is why nobody trains from scratch for document QA in practice;
  it is here to make the fine-tune and RAG trade-offs visible.

---

## 4. Track 3 — RAG (repo H)

### 4.1 What RAG is

No training. At index time, documents are split into chunks, each chunk is turned into an embedding vector, and
the vectors are stored. At question time the question is embedded, the nearest chunks are retrieved, and they
are put into the prompt of a normal LLM, which answers *from* them and cites them.

```
index:    doc-hr-001.txt ──chunk──► [c1, c2, ...] ──embed──► vectors ──► vector store hr-documents
query:    "How much notice ...?" ──embed──► q ──nearest──► [c1 of doc-hr-001] ──► prompt ──► gpt-4.1-mini ──► answer + 【doc-hr-001.txt】
```

### 4.2 The code

Foundry manages the chunking, embedding and search, so the whole track is two scripts:

```python
# rag/fetch_documents.py — Blob curated/documents/doc-hr-*.txt → data/hr/, with your Entra identity
container.download_blob(blob.name).readall()

# rag/create_agent.py
ids = [client.files.upload_and_poll(file_path=str(f), purpose=FilePurpose.AGENTS).id for f in files]
store = client.vector_stores.create_and_poll(file_ids=ids, name="hr-documents")     # chunk + embed + index
tool = FileSearchTool(vector_store_ids=[store.id])
agent = client.create_agent(model="gpt-4.1-mini", name="docintel-hr-agent",
                            instructions=INSTRUCTIONS, tools=tool.definitions, tool_resources=tool.resources)
```

The instructions carry the security posture: *always search first, answer only from what the search returns,
quote the figure and the file, say so if it is not there, never use general HR knowledge*. The run steps show a
`file_search` tool call before the message, and the answer carries `【n:m†doc-hr-NNN.txt】` citations.

### 4.3 Deployment flow

```
(reuses the AI Services account and project — no Azure ML, no endpoint, no GPU)
python rag/fetch_documents.py      Blob → data/hr/
python rag/create_agent.py         vector store + agent + three test questions
```

### 4.4 Why RAG here, and when it wins

- **Changing data**: edit a policy, re-upload the file, the answer changes. No retraining.
- **Citations**: every answer names its source chunk — auditable in a way weights never are.
- **Refusal is natural**: nothing retrieved → nothing to answer from → "the documents do not contain this".
  The two trained tracks have to *learn* refusal and do it imperfectly.
- **Scales past unique handles**: thousands of documents from the same vendor are fine because retrieval finds
  the right one; closed-book recall cannot.
- **Cost**: no endpoint, no training; vector store storage is negligible; you pay per token on gpt-4.1-mini.
- **Its own risks**: the corpus is an injection surface (a planted "HR-209 revision" is cited as fact — the
  workshop's session-2 demo), retrieval can miss, and every answer depends on the reasoning model's honesty.
- **Why Foundry's vector store rather than Azure AI Search**: ten documents; the managed store is one call and
  zero infrastructure. AI Search is the step up when you need hybrid search, filters, your own chunking or
  document-level ACLs.

---

## 5. The common agent layer (all three)

Every track ends in the same place: a Foundry agent on `gpt-4.1-mini` in project `docintel-finance`.

```
user ─► (Copilot ─► Bot Service) ─► agent ─► gpt-4.1-mini decides ─► tool ─► answer relayed verbatim
                                                                      │
                                       finance: OpenAPI → ML endpoint (managed identity, audience ml.azure.com)
                                       employee: OpenAPI → ML endpoint (same)
                                       HR:       file_search → vector store
```

- **Why an agent at all**: it turns a model endpoint into something a user can talk to in Copilot, adds routing
  (finance question → tool, anything else → plain answer), conversation memory (threads), traces (run steps),
  and one identity to reason about.
- **Why OpenAPI tools with managed-identity auth**: the endpoint has no keys; the project's identity gets an
  Entra token for `https://ml.azure.com` and a scoped `AzureML Data Scientist` role. The tool spec is a file in
  the repo; the live scoring URL is filled in at run time.
- **Why "reply verbatim"**: the reasoning model must not "improve" a memorised number. Instructions forbid guessing.
- **The classic → versioned migration**: `create_agent.py` uses the Assistants-style API; "Save as new agent" in
  the portal copies it to the versioned API that the playground and Copilot use; `publish_version.py` pushes new
  instructions to that copy and strips the `web_search` tool the portal adds.

---

## 6. Tech stack, in one table

| Layer | Finance (fine-tune) | Employee (from scratch) | HR (RAG) |
|---|---|---|---|
| Data | Blob curated JSONL 615/61/123 via datastore | Blob curated JSONL 330/33/66 via datastore | Blob curated OCR texts ×10 |
| Libraries | torch 2.3.1, transformers 4.46.1, peft 0.13.2, bitsandbytes 0.44.1, datasets | torch 2.3.1 only | azure-ai-agents, azure-storage-blob |
| Training | Azure ML command job, `gpu-t4`, QLoRA, 3 h 15 min | Azure ML command job, `gpu-t4`, 77 s | none |
| Artefact | `docintel-qwen-adapter:2` (110 MB) | `employee-from-scratch-model:1` (13 MB, vocab inside) | vector store `hr-documents` |
| Serving | managed online endpoint, T4, `score.py` + PeftModel, ~1 s | managed online endpoint, DS1_v2, `score.py`, ~150 ms | Foundry `file_search` |
| Agent | `docintel-finance-agent`, OpenAPI tool | `docintel-employee-agent`, OpenAPI tool | `docintel-hr-agent`, file_search |
| Identity | project managed identity → AzureML Data Scientist on endpoint | same | your identity → Blob Reader; agent identity → project |
| IaC / ops | Terraform (workspace, clusters, ACR, KV, App Insights, AI Services, roles), `az ml` YAML | reuses F | none needed |
| Cost while idle | endpoint ~$0.53/h (delete between demos) | endpoint ~$0.06/h | ~0 |

---

## 7. Choosing between them — the rule of thumb

1. **Does the data change, or must answers be cited?** → RAG.
2. **Must the answer come from a model you fully own, with no retrieval step, and is the corpus small and
   stable?** → fine-tune an open model (LoRA/QLoRA).
3. **Do you need to *show* what weights are, or build a tiny task-specific model with no external dependency?**
   → from scratch — otherwise never.

In production the usual answer is RAG first, fine-tuning to teach *style, format or a narrow skill*, and both
together (a fine-tuned model behind a RAG agent) when you need the strengths of each.

---

## 8. Build order if you were starting again

1. Ingestion repo: Terraform → `run_all.sh` → confirm `curated/` in Blob.
2. Fine-tuning repo: Terraform → datastore + assets → job → register → endpoint → `test_endpoint.py`.
3. Project + roles → `agent/create_agent.py` → portal migration → Copilot publish.
4. Employee repo: assets → job (seconds) → endpoint on CPU → `foundry/create_agent.py`.
5. HR repo: `fetch_documents.py` → `create_agent.py`.
6. Workshop repo: the four notebooks against everything above.

Every README is a runbook for its step; every command in them was run to produce the numbers quoted here.
