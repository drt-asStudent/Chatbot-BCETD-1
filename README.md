# BCETD — Academic Assistant for Lucian Blaga University of Sibiu

A production-grade Retrieval-Augmented Generation (RAG) system that answers student questions about programs of study, regulations, faculty leadership, course tutors, admissions, and other official information published by Universitatea Lucian Blaga din Sibiu. Every response is grounded in the institution's own documents and includes a citation to its source.

> **Language scope.** The assistant operates exclusively in Romanian. The system message explicitly instructs the model to respond only in Romanian, regardless of the input language. Adversarial cases in other languages are politely redirected. All sample documents, regulations, and indexed content are Romanian.

---

## Executive summary

| Dimension | Value |
|-----------|-------|
| Domain | Romanian higher education — Faculty of Engineering, ULBS |
| Primary use case | Student-facing question answering over institutional documents |
| Interface language | Romanian (responses always in RO; refuses to answer in other languages) |
| Technology stack | Python (Flask), n8n, Qdrant, PostgreSQL, OpenAI GPT-4o-mini |
| Deployment model | Docker Compose (4 core services + 2 optional) |
| Indexed content | ~170 chunks from 47 ULBS web pages + selected local PDFs |
| Median response latency | 3–5 seconds |
| Cost per query | ~$0.0008 (gpt-4o-mini + text-embedding-3-small) |
| Team composition | 5 engineers across infrastructure, RAG, safety, analytics, frontend |
| Project status | Production-ready, validated end-to-end |

---

## What the system does

Students access the chat interface at `http://localhost:3000` and submit questions. The assistant always responds in Romanian. Internally, on each query:

1. **Classifies the question** through a structured three-protocol decision system embedded in the AI Agent's system message — off-topic, general ULBS knowledge, or specific institutional information.
2. **Retrieves relevant content** from a Qdrant vector store containing scraped ULBS web pages and ingested local documents (PDF, DOCX, TXT).
3. **Generates a grounded Romanian-language answer** citing the source document or page as a clickable chip in the chat UI.
4. **Logs anonymized analytics** to PostgreSQL via a direct insert from the query pipeline, feeding an administrative dashboard.
5. **Refuses inappropriate or out-of-scope requests** through prompt-level safety controls validated against an adversarial test suite of 57 cases.

For dynamic data such as the live class timetable, the system redirects students to the authoritative source (`schedule.ulbsibiu.ro`) rather than serving potentially stale indexed content.

### Representative interactions

| Query type | Example (Romanian) | Expected behavior |
|------------|--------------------|-------------------|
| Specific factual | *"Cine sunt tutorii pentru anul I de Master?"* | Lists all four specializations with named tutors; cites source page |
| List enumeration | *"Care sunt specializările de master?"* | Returns all four programs (ACS, ES, ICAI, AAIE) |
| Disambiguation | *"Cine sunt decanii?"* | Asks whether the user means deans of year or the faculty dean |
| General knowledge | *"Câte facultăți are ULBS?"* | Answers directly from the prompt's fact sheet (no retrieval) |
| Off-topic | *"Cine a câștigat Champions League?"* | Polite refusal redirecting to ULBS topics |
| Foreign language | *"What are the master programs?"* | Replies in Romanian explaining the assistant operates only in Romanian |
| Dynamic data | *"Care e orarul grupei 221?"* | Redirects to `schedule.ulbsibiu.ro` |

---

## Architecture

```
                          ┌──────────────────────────┐
                          │  Student (web browser)   │
                          └────────────┬─────────────┘
                                       │ HTTP
                          ┌────────────▼─────────────┐
                          │  Frontend (Flask)        │   port 3000
                          │  Owner: Member 5         │
                          └────────────┬─────────────┘
                                       │ HTTP proxy
                          ┌────────────▼─────────────┐
                          │  n8n Workflow Engine     │   port 5678
                          │  Owners: Members 2, 3, 4 │
                          └─┬─────────┬─────────┬────┘
                            │         │         │
              ┌─────────────▼─┐  ┌────▼────┐  ┌─▼────────────────┐
              │ OpenAI API    │  │ Qdrant  │  │ PostgreSQL        │
              │ embeddings    │  │ vectors │  │ anonymous metrics │
              │ + completion  │  │ :6333   │  │ :5432             │
              └───────────────┘  └─────────┘  └───────────────────┘
```

The system runs as **four Docker containers** orchestrated by a single `docker-compose.yml`:

| Container | Image | Default port | Responsibility |
|-----------|-------|--------------|----------------|
| `bcetd-frontend` | Built from source | **3000** | Serves the chat UI and admin dashboard; proxies requests to n8n |
| `bcetd-n8n` | `n8nio/n8n:latest` | **5678** | Hosts all workflow logic: ingestion, query pipeline, analytics |
| `bcetd-qdrant` | `qdrant/qdrant:latest` | **6333** (HTTP), 6334 (gRPC) | Vector database holding embedded document chunks |
| `bcetd-postgres` | `postgres:16-alpine` | **5432** | Anonymous analytics with 90-day retention on raw logs |

Ports are parameterized through `.env`; the defaults above apply when no override is set. Two optional services are available via Compose profiles: `bcetd-ollama` (port 11434) for local LLM inference and `bcetd-grafana` (port 3001) for external dashboarding.

---

## Team responsibilities

The repository is organized into five top-level folders, one per engineering role. Each folder represents a clear boundary of ownership: changes inside a folder are reviewed by the owning member; cross-cutting changes are coordinated among the affected owners through pull request review.

### Member 1 — Infrastructure & DevOps
`member1-infrastructure/`

Owns the container topology, startup scripts, health monitoring, and CI/CD pipeline. Delivers a one-command setup (`docker compose up -d`) that produces a working system from a fresh clone given a valid `.env`.

**Key deliverables:** parameterized Docker Compose orchestration, automated startup and health check scripts, Grafana datasource configuration, GitHub Actions CI pipeline, and a Windows document conversion helper for local file preparation.

### Member 2 — RAG Pipeline Engineer
`member2-rag-pipeline/`

Owns the n8n workflows that constitute the retrieval-augmented generation pipeline:

| File | Role | Trigger |
|------|------|---------|
| `01_web_api_ingestion.json` | Scrapes the ULBS public REST API, applies content filtering, splits text into chunks, generates OpenAI embeddings, writes to Qdrant via the sub-workflow | Manual (recommended monthly) |
| `02_insert_page_to_qdrant.json` | Sub-workflow for atomic chunk upserts with structured metadata | Called by `01` and `04` |
| `03_student_query_pipeline.json` | Webhook endpoint that runs the AI Agent with vector search, formats responses in Romanian, and writes analytics directly to PostgreSQL | Webhook `/webhook/chat` |
| `04_document_ingestion_pipeline.json` | Ingests local PDF/DOCX/TXT files from `data/documents/` into the same vector store | Manual |

The agent's behavior is specified by a structured **three-protocol system message** that **enforces Romanian-only responses**:

- **Protocol A** — Off-topic refusal: returns a fixed Romanian template without invoking the retrieval tool.
- **Protocol B** — General ULBS knowledge (faculty list, central contact, public websites): answered directly in Romanian without retrieval.
- **Protocol C** — Specific institutional information: mandatory retrieval, mandatory source citation, response in Romanian only.

The system message also encodes disambiguation rules for queries that could otherwise match unrelated content (for example, distinguishing "decani" from "members of the department council"). Detailed prompt design and parameters are documented in `member2-rag-pipeline/SYSTEM_PROMPT_DOCUMENTATION.md`.

**Production parameters:** 800-character chunks with 100-character overlap; retrieval limit of 5; `gpt-4o-mini` at temperature 0.2; conversational memory of 3 turns; maximum 800 output tokens to support list-heavy Romanian responses without truncation.

### Member 3 — Ethics & Guardrails Engineer
`member3-ethics-guardrails/`

Owns the safety specification and validation. In the current architecture, the safety logic is implemented inline in the AI Agent's system message rather than as separate n8n workflows; see `member3-ethics-guardrails/workflows/deprecated/README.md` for the rationale and metrics that justified the consolidation.

Member 3 maintains ownership of:

- The 57-case adversarial test suite (`adversarial_test_suite.json`)
- The blocklist of inappropriate terms (`blocklist.txt`)
- The automated test runner that exercises the live system end-to-end (`test_guardrails.sh`)

This is a deliberate separation of **specification (Member 3)** from **implementation (Member 2)**: Member 3 defines what must be refused and provides the test cases; Member 2 places the refusal logic in the LLM's instructions; Member 3's test suite verifies the result against the live system. The split allows the safety contract to evolve independently of the prompt engineering.

### Member 4 — Analytics & Database Engineer
`member4-analytics/`

Owns the PostgreSQL schema, the analytics API exposed to the admin dashboard, daily aggregation, and the Grafana dashboard configuration. The schema persists only anonymous metrics — query content is never stored in plaintext, only its SHA-256 hash alongside response metadata (category, latency, matched documents, anonymous rotating session identifier).

Daily statistics are computed by a cron-scheduled n8n workflow that aggregates the previous day's logs and applies a 90-day retention purge on the raw log table. Aggregated daily tables are retained indefinitely.

In the current architecture, analytics rows are inserted directly by the query pipeline through a Postgres node, replacing the original sub-workflow design (see `member4-analytics/workflows/deprecated/README.md` for the rationale and trade-off analysis).

### Member 5 — Frontend & Integration Engineer
`member5-frontend-python/`

Owns the Flask application: the Romanian-language chat UI, the admin dashboard, the HTTP client to n8n (with retry and timeout handling), session management, and the integration test suite. The frontend renders responses with structured source citations as clickable chips, applies the ULBS visual identity to the interface, and exposes a `/api/health` endpoint that monitoring tools can probe.

---

## Repository structure

```
chatbot-bcetd/
├── README.md                            ← You are here
├── docker-compose.yml                   ← Orchestration for all 4 core services
├── .env.example                         ← Template for credentials (real .env is gitignored)
├── .gitignore
├── .github/workflows/                   ← CI pipeline
│
├── member1-infrastructure/              ← DevOps
│   ├── grafana/datasources.yml
│   └── scripts/
│       ├── start.sh                     ← Linux/macOS one-command startup
│       ├── healthcheck.sh
│       └── convert-documents.ps1        ← Windows helper for local document preparation
│
├── member2-rag-pipeline/                ← RAG pipeline
│   ├── SYSTEM_PROMPT_DOCUMENTATION.md   ← AI Agent system message reference
│   └── workflows/
│       ├── README.md                    ← Import procedure and parameter tuning
│       ├── 01_web_api_ingestion.json    ← Active
│       ├── 02_insert_page_to_qdrant.json ← Active (sub-workflow)
│       ├── 03_student_query_pipeline.json ← Active
│       ├── 04_document_ingestion_pipeline.json ← Active (local files)
│       └── deprecated/                  ← Historical artifacts from earlier iterations
│
├── member3-ethics-guardrails/           ← Safety specification & validation
│   ├── blocklist.txt
│   ├── adversarial_test_suite.json
│   ├── test_guardrails.sh
│   └── workflows/
│       ├── README.md                    ← Explains absence of active workflows
│       └── deprecated/                  ← Original layered guardrail workflows
│           ├── M3- Ethics Guardrails (Sub-Workflow).json
│           └── M3- Output Validation (Layer 3).json
│
├── member4-analytics/                   ← Database, dashboard, aggregation
│   ├── sql/001_initial_schema.sql       ← Tables, views, functions
│   ├── workflows/
│   │   ├── workflow_analytics_api.json  ← Active (dashboard endpoints)
│   │   ├── workflow_daily_stats.json    ← Active (cron aggregation)
│   │   └── deprecated/                  ← Original logging sub-workflow
│   ├── scripts/backup_database.sh
│   └── grafana_dashboard.json
│
├── member5-frontend-python/             ← Flask application (Romanian UI)
│   ├── Dockerfile
│   ├── requirements.txt
│   ├── run.py
│   ├── setup.cfg
│   ├── app/                             ← Routes, services, templates, static assets
│   └── tests/test_app.py
│
├── shared/api_contract.json             ← Webhook API specification (Flask ↔ n8n)
├── data/documents/                      ← Local PDFs available for ingestion via workflow 04
└── backups/postgres/                    ← Daily database backups (gitignored)
```

### About the `deprecated/` folders

Several member folders ship a `deprecated/` subdirectory. **These directories preserve historical artifacts from earlier iterations of the architecture** and are not loaded by the running system. They are kept under version control for three reasons:

1. **Design traceability** — they document why the current architecture was chosen over alternatives
2. **Audit trail** — they preserve the decisions made during the development cycle for academic and review purposes
3. **Recovery option** — if a regression is ever discovered, the older designs remain accessible

Each `deprecated/README.md` explains what was retired, why, and what active component now replaces it. Concretely:

| Location | Contains | Replaced by |
|----------|----------|-------------|
| `member2-rag-pipeline/workflows/deprecated/` | Earlier iteration of the query pipeline (`Versiune_anterioara_progress.json`) | The current 03_student_query_pipeline with consolidated Protocol A/B/C |
| `member3-ethics-guardrails/workflows/deprecated/` | The original three-layer guardrail design (`M3- Ethics Guardrails (Sub-Workflow).json`, `M3- Output Validation (Layer 3).json`) | Safety logic moved inline into the AI Agent's system message |
| `member4-analytics/workflows/deprecated/` | The original async logging sub-workflow (`workflow_analytics_logging.json`) | Direct PostgreSQL insert from the query pipeline |

**Do not import deprecated workflows into a live n8n instance** — they may reference credentials or workflow IDs that no longer exist, and they have been superseded by simpler designs validated in production.

---

## Deployment

The system deploys as a single Docker Compose stack. The procedure below produces a working installation in under 15 minutes on a fresh machine.

### 1. Prerequisites

- Docker Desktop (Windows / macOS) or Docker Engine + Compose v2 (Linux), version 24 or later
- 8 GB RAM available (16 GB recommended for development)
- 10 GB free disk space
- An OpenAI API key with credit for `gpt-4o-mini` and `text-embedding-3-small`

### 2. Clone and configure

```bash
git clone <repository-url>
cd chatbot-bcetd
cp .env.example .env
```

Open `.env` and provide values for:

```env
OPENAI_API_KEY=sk-...
N8N_USER=admin
N8N_PASSWORD=<strong password>
POSTGRES_PASSWORD=<strong password>
```

All ports default to standard values (3000 for the chat UI, 5678 for n8n, 6333 for Qdrant, 5432 for PostgreSQL). To run alongside another instance — for example to test changes without affecting a running deployment — override the port variables in `.env`.

### 3. Start the services

```bash
docker compose up -d
docker compose ps
```

All four containers should reach `Up` status within 60 seconds.

### 4. Import the n8n workflows

Open `http://localhost:5678`, authenticate with the credentials from `.env`, and import the workflows in the order below.

From `member2-rag-pipeline/workflows/`:

1. `02_insert_page_to_qdrant.json` — import first and note its workflow ID (it is the sub-workflow called by 01 and 04)
2. `01_web_api_ingestion.json` — update its reference to the sub-workflow ID
3. `03_student_query_pipeline.json` — toggle **Active** to enable the webhook
4. `04_document_ingestion_pipeline.json` — optional, for ingesting local files

From `member4-analytics/workflows/`:

5. `workflow_analytics_api.json` — toggle **Active** (exposes dashboard data endpoints)
6. `workflow_daily_stats.json` — toggle **Active** (cron-scheduled daily aggregation)

For each workflow, configure credentials when prompted:

- **OpenAI** — use the key from `.env`
- **Qdrant** — URL `http://qdrant:6333` (internal Docker DNS, not `localhost`)
- **PostgreSQL** — host `postgres`, user and password from `.env`

### 5. Populate the vector store

In n8n, open `01_web_api_ingestion` and click **Execute workflow**. The pipeline scrapes the ULBS public API, filters and chunks the content, generates embeddings, and writes to Qdrant in 2–5 minutes.

Verify completion:

```bash
curl http://localhost:6333/collections/ulbs_documents
```

Expect `points_count` between 150 and 300.

To ingest the local PDFs from `data/documents/` (`Regulament_HSE.pdf`, `CodeQuest.pdf`, `Rezultate_CodeQuest.pdf`), execute `04_document_ingestion_pipeline` from the n8n UI.

### 6. End-to-end test

Open `http://localhost:3000` and submit a Romanian-language query:

> *Care sunt specializările de master de la Inginerie?*

A coherent Romanian response with a clickable source chip indicates the system is operational end-to-end. Visit `http://localhost:3000/admin/` to confirm the analytics dashboard is recording activity.

---

## Operations

### Re-indexing content

The ULBS website is updated periodically. To refresh the index:

```bash
curl -X DELETE http://localhost:6333/collections/ulbs_documents
```

Then re-run `01_web_api_ingestion` from the n8n UI. The chat remains available during re-indexing — queries continue against the previous index until the new one is in place.

### Database backups

A backup script with 7-day rotation is provided:

```bash
bash member4-analytics/scripts/backup_database.sh
```

Backups land in `backups/postgres/` (gitignored).

### Frontend updates

Only the frontend container is built from source. When frontend code changes:

```bash
docker compose up -d --build frontend
```

The other three containers (n8n, Qdrant, PostgreSQL) use upstream images and never need rebuilding; their state lives in named Docker volumes and persists across container restarts.

### Lifecycle commands

```bash
docker compose stop          # Stop containers, keep data
docker compose start         # Resume
docker compose down          # Stop and remove containers, keep volumes
docker compose down -v       # WARNING: also deletes all volumes (full reset)
```

---

## Tuning parameters

The system is calibrated through a small set of high-impact parameters that operators can adjust without modifying code.

### AI Agent (`03_student_query_pipeline` → `OpenAI Chat Model2`)

| Parameter | Default | Effect when increased |
|-----------|---------|----------------------|
| Model | `gpt-4o-mini` | Switching to `gpt-4o` improves nuance at approximately 6× the cost |
| Temperature | 0.2 | Higher values increase variability; not recommended for factual Q&A |
| Maximum tokens | 800 | Allows longer responses; raise to 1500 for complex regulations |

### Retrieval (`03_student_query_pipeline` → `university_documents_search1`)

| Parameter | Default | Effect when increased |
|-----------|---------|----------------------|
| Limit | 5 | More chunks improve recall for list-style questions; approximately +15% tokens per increment |

### Conversational memory (`03_student_query_pipeline` → `Simple Memory2`)

| Parameter | Default | Effect when increased |
|-----------|---------|----------------------|
| Context window | 3 | Longer memory improves multi-turn coherence; approximately +500 tokens per additional turn |

### Ingestion chunking (`01_web_api_ingestion` → text splitter)

| Parameter | Default | Effect |
|-----------|---------|--------|
| Chunk size | 800 | Smaller chunks improve precision but fragment lists; larger chunks improve coverage of structured content |
| Chunk overlap | 100 | Higher overlap reduces information loss at chunk boundaries |

> **Language constraint.** The Romanian-only response policy is enforced through the system message and is not exposed as a tuning parameter. Any attempt to change response language requires editing the system message in `03_student_query_pipeline` and re-running the adversarial test suite to confirm safety properties are preserved.

---

## Privacy and security

- **No personal data is stored.** Session identifiers are random UUIDs generated server-side; they do not link to any user account or browser identity.
- **Query content is never persisted in plaintext.** Only the SHA-256 hash of the normalized query is logged, alongside response metadata.
- **Credentials live exclusively in `.env`** (excluded from version control). The repository ships `.env.example` as a template.
- **Retention policy:** raw query logs are purged after 90 days by the cron-scheduled aggregation workflow; aggregated daily statistics are retained indefinitely.
- **For production deployment**, place the system behind a reverse proxy with HTTPS termination (Nginx or Caddy), enable n8n's basic authentication, and restrict Qdrant and PostgreSQL ports to the Docker internal network.

---

## Performance and economics

### Typical per-query consumption (gpt-4o-mini)

| Component | Tokens |
|-----------|--------|
| System message | ~2,000 |
| Conversational memory (3 turns) | 1,500–3,500 |
| Retrieved chunks (limit = 5) | 3,000–4,000 |
| Generated response | 400–800 |
| **Total average** | **~6,000–8,000** |
| Peak (long list questions) | ~16,000 |

### Monthly cost projection

| Daily volume | Approximate monthly cost |
|--------------|--------------------------|
| 50 queries | $1.50 |
| 200 queries | $6.00 |
| 500 queries | $15.00 |
| 1,000 queries | $30.00 |

The system has been operated at this efficiency level by the team during testing. No infrastructure scaling has been necessary at volumes below 1,000 queries per day.

---

## Troubleshooting

| Symptom | First diagnostic step | Likely fix |
|---------|----------------------|-----------|
| Chat displays "Cannot connect to server" | `curl http://localhost:3000/api/health` | If `n8n_reachable: false`, run `docker compose restart n8n`. If `true`, verify `03_student_query_pipeline` is **Active** in the n8n UI. |
| Answers consistently return *"Nu am găsit această informație..."* | `curl http://localhost:6333/collections/ulbs_documents` | If `points_count < 100`, re-run `01_web_api_ingestion`. |
| Responses are cut off mid-sentence | Inspect node `OpenAI Chat Model2` in `03_student_query_pipeline` | Increase **Maximum Number of Tokens** (commonly from 400 to 800 or higher). |
| Changes in the n8n UI do not appear in the live chat | Inspect the workflow status badge | Workflows with webhook triggers must be deactivated and re-activated after structural changes. Verify no two active workflows share the same webhook path. |
| Dashboard shows zero queries despite chat traffic | `docker exec bcetd-postgres psql -U chatbot_user -d chatbot_stats -c "SELECT COUNT(*) FROM query_logs;"` | If zero, verify the Postgres insert nodes at the tail of `03_student_query_pipeline` are connected to the FALSE branch of `Split Response / Analytics`. |
| Assistant replies in English or another language | Inspect node `AI Agent2` → System Message | Confirm the directive *"Răspunzi EXCLUSIV în limba română"* is present at the top of the system message. |

---

## Project status

The system has been validated end-to-end against the full adversarial test suite, the analytics dashboard reflects live query traffic, and all five team areas have completed their primary deliverables. The codebase is suitable for handover to a maintenance team or for continued feature development.

For new contributors: begin with the folder corresponding to the area you intend to modify, read its local `README.md` where present, and follow the contribution conventions agreed by the team. Cross-area changes should be coordinated with the affected member owners through pull request review.
