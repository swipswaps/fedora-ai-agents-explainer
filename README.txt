FEDORA AI AGENTS EXPLAINER
==========================

PROJECT PURPOSE
---------------
See AUDIT.txt for the conversation audit, source corrections, implementation scope, and explicit non-claims.
This repository contains an Omarchy-inspired, Fedora-native AI coding-agent
explainer and a local reference implementation. The public GitHub Pages site is
static. The local data plane is a separate FastAPI service running in Docker
Compose and backed by SQLite.

The project intentionally separates three capabilities:

1. Agent discovery and launching. An executable being present does not prove
   that the agent is authenticated or that its subscription usage is measurable.
2. Usage collection. Collectors are independent adapters that normalize local
   usage metadata into a stable usage-event contract.
3. Visualization and query. The React interface displays backend capabilities,
   token summaries, and local knowledge retrieval. It does not own agent secrets.

PUBLIC SITE
-----------
https://swipswaps.github.io/fedora-ai-agents-explainer/

SOURCE
------
https://github.com/swipswaps/fedora-ai-agents-explainer

ONE-SHOT BUILD AND PUBLISH
--------------------------
From the directory containing build-fedora-ai-agents-explainer.sh, run:

  bash build-fedora-ai-agents-explainer.sh

The builder preflights Node.js, npm, Python, Docker/Compose, Git, GitHub CLI
authentication and xdg-open. It writes every repository file through idempotent
heredoc writers, backs up replaced files, verifies generated-file SHA-256 values,
installs npm and Python dependencies, runs the Vite build and pytest suite,
validates/builds the Docker image, creates or reuses the public GitHub repository,
pushes main, configures GitHub Pages Actions deployment before the triggering
push, polls the GitHub REST API for a successful workflow run on the exact commit,
checks the Pages REST representation, verifies the deployed HTML and every Vite
JavaScript/CSS asset over HTTPS, and only then opens the site with xdg-open.

For source-generation inspection only (not a full build or publication):

  SKIP_DEPENDENCY_INSTALL=1 SKIP_PUBLISH=1 bash build-fedora-ai-agents-explainer.sh

A source-only run must not be described as a validated production build.

LOCAL DEVELOPMENT
-----------------
Requirements:
- Fedora 43 is the primary documented target.
- Xfce X11 is supported; no Wayland, GNOME, or Hyprland dependency is required.
- Node.js 20.19+ or 22.12+ and npm.
- Python 3.11 or newer for local tests and utilities.
- Docker Engine and Docker Compose v2 plugin.
- Git and curl.

From the repository directory, first install dependencies (this creates the lockfile on a fresh source archive):

  npm install --no-audit --no-fund

Then start the local backend and UI:

  docker compose up --build -d
  npm ci
  npm run dev

Open http://127.0.0.1:5173/ . The API is published only on
http://127.0.0.1:8000 and is not exposed to the LAN.

INSTALLER
---------
Run:

  bash install-fedora-ai-agents.sh

The installer checks prerequisites, starts the local Docker backend, creates a
user-level systemd service for the Vite development server, creates a 15-minute
systemd user timer for host agent detection and OpenCode usage collection, creates
Xfce-compatible dashboard and agent-launcher entries, validates the API, and
opens the local site.

The separate install-opencode.sh helper uses the current official OpenCode V2 installer and verifies opencode --version; it is opt-in and is not run by the dashboard installer. It is install-if-absent and deliberately leaves any existing V1 or V2 executable untouched. OpenCode V1 and V2 share the default opencode command and are not installed side by side by default. To upgrade an existing V1 installation, back up its configuration and follow https://opencode.ai/docs/migrate-v1/ explicitly. Inspect configured providers with opencode auth list; authenticate a provider with opencode auth login PROVIDER_ID (for example, anthropic). The official CLI also exposes opencode stats --json for native usage summaries. Omarchy's broader agent collectors provide additional provider-aware usage and quota integrations; this project deliberately implements a narrower local OpenCode usage projection and does not claim provider subscription quotas. The installer creates two desktop entries: the local dashboard and a coding-agent menu. The menu detects installed OpenCode, Claude Code, Codex, Gemini CLI, Pi, and Copilot executables; it launches only detected commands from a fixed allowlist. It does not install or authenticate those agents.

The installer does not overwrite ~/.config/opencode, edit OpenCode auth data,
modify the OpenCode SQLite database, or remove Docker volumes. The source
OpenCode data stays on the Fedora host. The collector runs as the logged-in user and sends only normalized usage metadata to the loopback API; no OpenCode directory is mounted into Docker.

OPENCODE USAGE COLLECTION
-------------------------
The standalone host adapter detects the actual OpenCode database schema rather
than inferring it from a CLI version. V1 message rows and V2 assistant
session_message.data rows are projected to per-message usage metadata using
SQLite JSON1. Only provider/model, time, token and cost paths are returned;
message content and tool output are not selected as result columns. V2
session_v2 (or newer session) cumulative counters are retained as a fallback
for sessions whose assistant rows do not expose usage counters. The API stores
those cumulative snapshots and computes positive deltas against the preceding
snapshot, avoiding repeated totals. The first fallback collection is a baseline:
it attributes existing session counters to the first observation time, not to
historical message dates. Later fallback deltas are timestamped at the 15-minute
observation time. If a cumulative counter decreases, the API records a reset
flag and treats the new counter value as a fresh positive delta; it never emits
negative token/cost usage. Per-message V2 model/provider attribution comes from each
assistant row; fallback attribution is session-level.

V1 and V2 assistant messages are filtered against their session creation
timestamp to avoid counting inherited pre-fork history. Message IDs are
idempotently deduplicated across the legacy and V2 stores. V2 assistant message
rows are projected without returning content arrays or tool output; session
aggregates are fallback metadata only. The source database is opened read-only by the logged-in
Fedora user. SQLite may read existing WAL/SHM sidecars as part of a read-only
WAL snapshot; the collector issues no writes or checkpoints and does not alter
the database's logical contents. The Docker container never mounts that database.

The host message scan is capped at 1,000,000 rows and normalized usage events at
100,000; schema mismatches fail explicitly rather than returning a partial result.

The dashboard displays reported input+output counters, with reasoning and cache
counters shown separately. Provider counter definitions can overlap, so the
application does not fabricate one billable-token total. Cost is OpenCode-reported;
zero cost does not establish that a provider supplied service for free. The
collector provides local usage accounting, not provider quota or subscription-
limit discovery. Provider-specific rate limits require separate, verified APIs.

DATABASE AND SEARCH
-------------------
The local database enables:
- SQLite Write-Ahead Logging (WAL), foreign keys and busy timeout.
- Explicit schema_migrations table.
- Usage event ledger with indexed time and agent/model fields.
- FTS5 full-text indexing for local knowledge documents.
- sqlite-vec vector index using 768-dimensional float vectors by default. sqlite-vec remains pre-1.0, so pinning and integration tests are important.
- Optional local embeddings from Ollama using nomic-embed-text.
- Hybrid lexical/vector result ranking when embeddings are available.
- SQLite online backup API and integrity checks.

Vector search is genuinely enabled by sqlite-vec. Semantic embeddings are not
fabricated: the backend requests them from a local Ollama server if reachable,
or accepts a caller-supplied vector of the configured dimension. Without an
embedding, the endpoint truthfully reports lexical-only search. To enable local
embedding generation, install Ollama, pull the model, and make its API reachable
from Docker:

  ollama pull nomic-embed-text

Then index a document (the API requests the embedding locally):

  curl -X POST http://127.0.0.1:8000/api/documents \
    -H 'Content-Type: application/json' \
    -d '{"title":"Local architecture note","body":"Agent collectors emit normalized usage events."}'

Without a reachable embedding model, the document is still indexed in FTS5 and
its response reports indexed_vector=false; no synthetic embedding is generated.

The default Compose URL is http://host.docker.internal:11434. On Fedora Docker
configurations where this host alias is unavailable, adjust the Compose host
mapping and verify /api/capabilities before relying on embeddings.

WAL is a same-host concurrency mechanism. Do not place the active SQLite database
on NFS/SMB or share the WAL database among different machines. Backups use the
SQLite online backup API; copying only the main database file while WAL is active
is not a reliable backup procedure.

GITHUB PAGES AND LOCAL BACKEND
------------------------------
GitHub Pages is static hosting. It cannot run Docker, FastAPI, or a persistent
SQLite database. The deployed HTTPS page does not attempt to probe an arbitrary
HTTP loopback endpoint because browser mixed-content restrictions prevent that
from being a reliable architecture.

For full runtime functionality, open the local instance at
http://127.0.0.1:5173/. The Vite development server proxies /api to the local
FastAPI service. The static Pages version remains an explainer and installer
landing page.

VALIDATION
----------
On a fresh source archive, create the dependency lock first:

  npm install --no-audit --no-fund

Then run repeatable validation:

  npm ci
  npm run build
  bash scripts/validate.sh
  python3 -m pip install -r requirements.txt
  PYTHONPATH=backend pytest -q backend/tests
  docker compose config --quiet

A full integration check additionally requires Docker to be running:

  docker compose up --build -d
  curl --fail http://127.0.0.1:8000/health
  curl --fail http://127.0.0.1:8000/api/capabilities

BACKUP AND RESTORE
------------------

Create a verified backup:

  bash scripts/backup_db.sh

Restore a previously verified backup:

  bash scripts/restore_db.sh /absolute/path/to/agents-backup.db

Backup uses SQLite's online backup API from inside the container, verifies
integrity, FTS5 and sqlite-vec, and copies the private backup to the host.
Restore creates a verified pre-restore backup, validates the incoming database,
stops the API, streams the file into a one-shot helper container, and atomically
replaces the database. It restarts and health-checks the API. If health fails,
it automatically restores the pre-restore database; a second host-side rollback
backup remains available. The supplied source backup is never modified.

SAFE UNINSTALL
--------------

  bash uninstall-fedora-ai-agents.sh

This stops/removes the user-level service and desktop entry. It deliberately
preserves the Docker volume. To destroy the database, first create and verify a
backup, then explicitly remove the named volume:

  docker volume rm fedora-ai-agents-data

Do not run that command unless permanent data deletion is intended.

BUILD AND PUBLISH
-----------------
The root build-fedora-ai-agents-explainer.sh is the one-shot, idempotent
heredoc-based repository generator. It performs preflight checks, writes files
atomically, backs up changed existing files outside the repository, validates
the frontend/backend/shell configuration, then uses GitHub CLI authentication
to create or update the public repository, push main, wait for the Pages
workflow, verify the deployed URL, and open it with xdg-open.

By default, the builder writes into the directory containing the builder itself;
there is no implicit ~/Documents project directory. Set PROJECT_DIR explicitly
only when you intentionally want a different target. Set SKIP_PUBLISH=1 only
when intentionally performing a local build without GitHub publication.
The script refuses to overwrite a dirty Git working tree or a repository whose
origin does not match the approved repository.

SECURITY BOUNDARIES
-------------------
- The API binds to 127.0.0.1 on the host.
- No provider secrets are copied into the frontend or database.
- The OpenCode source database is opened mode=ro/query_only on the host and is
  never mounted into Docker. SQLite may read normal WAL/SHM sidecars; no SQL
  writes or checkpoints are issued.
- The collector is usage-metadata-only and fails closed on schema errors.
- The uninstaller preserves persistent data.
- No Docker privileged mode, host PID namespace, or host root filesystem mount
  is required.

REFERENCES
----------
Omarchy AI manual:
https://omarchy.org/manual/ai/

Omarchy Agents plugin implementation:
https://github.com/omacom/omarchy/blob/quattro/shell/plugins/agents/README.md

OpenCode provider authentication:
https://opencode.ai/docs/cli/providers

OpenCode CLI commands (stats --json, auth list --format json, debug paths db):
https://opencode.ai/docs/cli/commands

OpenCode generated V2 SQLite schema:
https://github.com/anomalyco/opencode/blob/dev/packages/core/src/database/schema.gen.ts

OpenCode V2 per-message data guide (community implementation reference):
https://github.com/MaxAnderson95/my-opencode-setup/blob/main/skills/opencode-db-querying/SKILL.md

OpenCode upstream cost-reporting issue:
https://github.com/anomalyco/opencode/issues/60624

Current Omarchy OpenCode collector implementation:
https://github.com/omacom/omarchy/blob/quattro/shell/plugins/agents/collectors.py

SQLite 3.54.1 release:
https://sqlite.org/releaselog/3_54_1.html

SQLite official source archive and checksums:
https://sqlite.org/download.html

Buildroot SQLite 3.54.1 SHA-256 package-maintainer record:
https://lists.busybox.net/pipermail/buildroot/2026-October/813774.html

SQLite Write-Ahead Logging:
https://www.sqlite.org/wal.html

SQLite FTS5:
https://www.sqlite.org/fts5.html

SQLite online backup API:
https://www.sqlite.org/backup.html

SQLite 3.54.1 release:
https://sqlite.org/releaselog/3_54_1.html

sqlite-vec source and API:
https://github.com/asg017/sqlite-vec

Docker Compose startup ordering and health checks:
https://docs.docker.com/compose/how-tos/startup-order/

Vite GitHub Pages deployment:
https://vite.dev/guide/static-deploy

Python sqlite3:
https://docs.python.org/3/library/sqlite3.html

FastAPI:
https://fastapi.tiangolo.com/

React:
https://react.dev/

Three.js:
https://threejs.org/docs/

D3.js:
https://d3js.org/

GitHub Pages:
https://docs.github.com/en/pages/getting-started-with-github-pages/creating-a-github-pages-site

systemd timer units:
https://www.freedesktop.org/software/systemd/man/latest/systemd.timer.html

systemd service units:
https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html

Kleppmann, Martin. Designing Data-Intensive Applications. O'Reilly, 2017.
ISBN 9781491903063 (first edition); ISBN 9781098119058 (second edition).
https://www.oreilly.com/library/view/designing-data-intensive-applications/9781491903063/

LIMITATIONS AND HONEST STATUS
-----------------------------
The OpenCode collector is implemented against the documented SQLite message
layout and must be tested against the actual installed OpenCode version before
being treated as production-compatible. The other listed agents are discovered
by executable name only; their usage collectors and provider quota APIs are not
claimed to be implemented. The frontend and database architecture are local-
first; GitHub Pages does not provide the runtime backend.
