# Aria Knight Memory Sidecar Implementation Plan

_Last updated: 2026-04-01_

## Goal

Replace brittle in-process / embedded long-term semantic memory behavior with a more reliable local-first sidecar memory architecture while preserving human-readable memory canon.

Primary objectives:

- Keep durable memory inspectable and editable by humans
- Move semantic retrieval out of the flaky embedded store path
- Reuse existing local infra already confirmed working
- Support future growth into structured / episodic / graph memory
- Minimize upgrade fragility inside AtomicBot / OpenClaw

---

## Current verified live state

### Canonical human-readable memory

Current canonical memory remains in the OpenClaw workspace:

- `MEMORY.md`
- `memory/YYYY-MM-DD.md`

These remain the source of truth for pinned facts, explicit rules, intentional decisions, and operator-authored memory.

### Existing OpenClaw built-in memory state

Observed during validation:

- built-in memory indexing/search exists
- embedded memory store behavior on this Windows AtomicBot/OpenClaw bundle showed SQLite lifecycle / lock / path weirdness
- `EBUSY` errors occurred during reindex/search operations
- attempts to move the store path exposed mismatched runtime/store behavior

Conclusion:

- built-in memory may remain useful as a fallback/reference
- it should **not** be treated as the primary durable semantic memory foundation

### Existing sidecar infrastructure already running

Verified locally:

#### Reranker sidecar

- container: `codee-memory-reranker`
- endpoint: `http://127.0.0.1:8780/rerank`
- health: `http://127.0.0.1:8780/health`
- info: `http://127.0.0.1:8780/info`
- model: `BAAI/bge-reranker-v2-m3`
- device: `cuda:0`
- dtype: `float16`

#### Qdrant

- container: `codee-qdrant-memory`
- local ports: `127.0.0.1:6333-6334`

### Existing AtomicBot/OpenClaw runtime patch

Verified local file-based reranker hook exists via:

- `C:\Users\TacIm\AppData\Roaming\atomicbot-desktop\openclaw\memory-rerank.json`
- patched runtime files in installed app bundle:
  - `...\openclaw\dist\entry.js`
  - `...\openclaw\dist\pi-embedded-Cq5UacYY.js`

This is a working tactical integration but is **upgrade-fragile**.

If AtomicBot/OpenClaw updates, these patched files may be overwritten.

---

## Recommended architecture

## Layer 0 — Pinned / human-authored memory (canonical)

Keep using markdown as canonical pinned memory:

- `MEMORY.md`
- `memory/YYYY-MM-DD.md`
- selected project notes/docs when explicitly included later

Use this layer for:

- explicit facts
- working agreements
- identity / preferences
- operator instructions
- decisions worth preserving intentionally

This layer must remain human-readable and editable.

## Layer 1 — Ingestion and provenance

Add a sidecar ingestion pipeline that:

- scans canonical files
- chunks content deterministically
- computes source hash / mtime / chunk IDs
- performs idempotent upserts into sidecar storage
- tracks provenance for every chunk

Minimum provenance fields:

- `source_path`
- `source_type` (`long_term`, `daily`, `project`, `other`)
- `file_hash`
- `chunk_id`
- `chunk_index`
- `created_at`
- `updated_at`
- `memory_scope`
- `tags` (optional)

Design principle:

- ingestion must be replayable
- source files remain canonical
- index is disposable/rebuildable

## Layer 2 — Retrieval substrate

Primary recommendation:

- **Qdrant** as the semantic memory backend

Qdrant stores:

- vectors
- payload metadata
- retrieval filter fields

Why Qdrant:

- already available locally
- already familiar to Richard
- strong local-first/self-hosted story
- better fit than overloaded embedded SQLite for long-term semantic retrieval

## Layer 3 — Ranking stack

Use hybrid retrieval:

1. lexical / exact retrieval (paths, IDs, terms, filenames, errors, dates)
2. semantic vector recall (Qdrant)
3. reranking via local sidecar (`bge-reranker-v2-m3`)
4. optional freshness/scope weighting

This avoids overreliance on pure vector similarity.

## Layer 4 — Structured memory promotion

After stable retrieval exists, add explicit promotion of durable items into structured memory records:

- preferences
- durable facts
- active project decisions
- recurring tasks
- known relationships / entities

This layer is phase 2, not phase 1.

## Layer 5 — Optional episodic / graph memory

Potential later direction:

- Graphiti-style entity/fact/episode graph
- relationship-aware recall
- time-aware contradiction handling

Not needed for initial stabilization.

---

## Initial sidecar schema proposal

## Qdrant collection

Recommended initial collection:

- `aria_memory`

Vector payload dimensions must match the existing embedding model actually chosen for ingestion.

### Payload fields

Suggested minimum payload schema:

- `source_path` (string)
- `source_type` (keyword)
- `memory_scope` (keyword)
- `title` (string, optional)
- `text` (string)
- `chunk_id` (keyword)
- `chunk_index` (integer)
- `file_hash` (keyword)
- `mtime_unix` (integer)
- `created_at` (datetime/string)
- `updated_at` (datetime/string)
- `tags` (keyword array)
- `importance` (float, optional)
- `pinned` (bool)

### Initial scopes

Recommended initial `memory_scope` values:

- `pinned`
- `daily`
- `project`
- `reference`

### Initial source mapping

- `MEMORY.md` -> `source_type=long_term`, `memory_scope=pinned`, `pinned=true`
- `memory/*.md` -> `source_type=daily`, `memory_scope=daily`, `pinned=false`
- later project docs -> `source_type=project`, `memory_scope=project`

---

## Chunking strategy

Initial recommendation:

- chunk size: roughly 300–500 tokens equivalent
- overlap: 50–100 tokens equivalent

Rules:

- do not split headings away from their content when avoidable
- preserve source section names when chunking
- store chunk text exactly enough for inspection/debugging
- deterministic chunk IDs should derive from source path + section + chunk index + file hash

---

## Retrieval flow

## Query path (recommended)

1. User/system asks a question requiring memory recall
2. Build retrieval query
3. Run lexical candidate search
4. Run semantic candidate search against Qdrant
5. Merge candidate pool
6. Send top candidate set to reranker
7. Return reranked results with provenance
8. Inject only the best subset into assistant context

### Candidate limits

Reasonable starting point:

- lexical candidates: 10–20
- vector candidates: 10–20
- merged candidate pool: 20–30
- reranked final set: 5–8

Tune later based on actual quality.

---

## Reranker role

Current verified reranker:

- `BAAI/bge-reranker-v2-m3`
- endpoint: `http://127.0.0.1:8780/rerank`

Role of reranker:

- improve precision after broader lexical/vector candidate recall
- reduce “topically close but wrong” hits
- prioritize exact operationally relevant chunks when multiple semantically similar memories exist

Do **not** use reranker as a substitute for proper retrieval design.

---

## Integration strategy with AtomicBot / OpenClaw

## Immediate position

Use sidecar architecture without making AtomicBot/OpenClaw app-bundle patching the permanent design center.

### Short-term

- existing patched rerank hook can remain in place temporarily
- use it as a tactical win while architecture is documented and stabilized

### Medium-term

Move toward one of these cleaner models:

1. an external sidecar service queried by a clean integration layer/tool/plugin
2. a maintained OpenClaw extension/plugin path if available
3. a small local bridge service that OpenClaw can call without patching installed app bundle files

### Avoid long-term reliance on

- direct edits inside installed `dist/*.js` app bundle files

Reason:

- app updates can wipe them
- difficult to diff/reapply safely
- opaque for future maintenance

---

## Phase plan

## Phase 1 — Stabilize and document

1. preserve current reranker/Qdrant setup documentation
2. keep markdown canon as source of truth
3. define Qdrant collection + payload schema
4. define ingestion contract
5. define retrieval + rerank flow
6. record upgrade-fragile patch points

Deliverable:

- implementation doc (this file)

## Phase 2 — Build minimal ingestion pipeline

1. ingest `MEMORY.md`
2. ingest `memory/*.md`
3. compute file hashes
4. perform idempotent upserts into Qdrant
5. verify rebuildability from source files only

Deliverable:

- reproducible local memory index build

## Phase 3 — Build query path

1. lexical candidate search
2. Qdrant vector search
3. merge + rerank
4. provenance-preserving result output
5. retrieval evaluation against known questions

Deliverable:

- sidecar recall path with measurable behavior

## Phase 4 — Connect assistant workflow

1. decide integration path into OpenClaw/AtomicBot runtime
2. expose sidecar memory search cleanly
3. keep fallback path until confidence is established

Deliverable:

- usable assistant memory path without depending on brittle internal store behavior

## Phase 5 — Structured memory promotion

1. promote durable facts/preferences/tasks into structured objects
2. support updates/supersession
3. preserve provenance back to source episodes/files

Deliverable:

- cleaner long-term memory semantics beyond chunk recall

## Phase 6 — Optional graph/episodic layer

Only after the above is stable.

---

## Adjacent operational workstreams

These are important, but intentionally ordered after the memory foundation work.

### A. Runtime disappearance / crash investigation

Observed reality:

- Richard reported Aria disappeared / crashed out and Codee had to restore service
- current quick inspection did **not** reveal a clean dedicated crash trace in the available logs
- currently visible logs are sparse (`config-audit.jsonl` present; no obvious app crash timeline captured in workspace logs)
- current session token usage is high enough that context pressure may be a contributing operational risk, but that is **not** yet a proven sole root cause

Working conclusion:

- disappearance/root-cause remains **partially unresolved**
- next diagnostic pass should gather a better crash timeline from AtomicBot/OpenClaw process logs, Windows Event Viewer if needed, restart sentinels, and session/runtime state
- do not claim a root cause before that evidence exists

Recommended order:

1. finish stabilizing memory substrate
2. collect a proper crash timeline
3. document likely causes and mitigations

### B. Local main-model cutover

Observed reality:

- current main assistant model is still `openai-codex/gpt-5.4`
- local vLLM at `http://127.0.0.1:8000/v1` is alive
- available local chat model verified: `huihui-qwen35-27b-abliterated-nvfp4`
- Richard explicitly wants reduced dependence on remote APIs because token exhaustion currently creates operational fragility

Recommended sequencing:

1. stabilize memory/retrieval path first
2. investigate disappearance/crash path second
3. then cut the main assistant model over to local vLLM carefully

Cutover notes:

- define an explicit `models.providers.vllm` entry or use supported local provider configuration against `http://127.0.0.1:8000/v1`
- add the model entry for `huihui-qwen35-27b-abliterated-nvfp4`
- switch `agents.defaults.model.primary`
- verify chat + tool behavior after restart
- keep a fallback path documented in case local-model behavior is insufficient for some tasks

---

## What to avoid

- making embedded SQLite vector memory the permanent architecture center
- relying on pure vector similarity with no lexical or rerank stage
- storing only opaque backend memory with no human-readable canon
- over-rotating into graph memory before retrieval stability exists
- assuming the current patched AtomicBot/OpenClaw bundle is durable
- changing embedding/reranker models immediately if the current proven pair already works

---

## Decision log

### Chosen direction

- Qdrant-first sidecar memory path
- pinned markdown canon retained
- local embeddings retained
- local reranker retained
- Hindsight treated as an evaluation track later, not immediate foundation

### Why

- current live infra already exists and is partially verified
- Richard already has prior success with Qdrant
- local reranker path is already running on the 5090
- built-in embedded memory path showed reliability concerns on this Windows bundle
- inspectable architecture is preferred before more magical orchestration layers

---

## Later evaluation track

After the sidecar baseline is working, evaluate:

- Hindsight as learned-memory orchestration layer
- Memoria as versioned/auditable memory experiment
- Graphiti-inspired episodic/relationship layer

These are later comparison tracks, not blockers to phase 1.

---

## Success criteria

The sidecar architecture is successful when:

- memory can be rebuilt entirely from canonical source files
- retrieval is more reliable than current built-in embedded behavior
- results are provenance-preserving and inspectable
- reranking measurably improves candidate ordering
- AtomicBot/OpenClaw updates do not destroy the entire memory architecture
- Richard can inspect, edit, and trust the durable memory canon
