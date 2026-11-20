"""Local-first FastAPI data plane for Fedora AI Agents Explainer.

Security invariants:
- The API is published by Compose on host loopback only.
- The OpenCode source database is never mounted into the Docker container.
- A host-side user process reads it mode=ro/query_only and posts only normalized
  usage metadata to the loopback API; prompts, content and auth are not selected.
- Provider credentials are never accepted by this API or returned to the browser.
"""
from __future__ import annotations

import hashlib
import json
import os
import sqlite3
import time
import urllib.error
import urllib.request
from contextlib import asynccontextmanager, contextmanager
from datetime import datetime, timezone, timedelta
from pathlib import Path
from typing import Any

import sqlite_vec
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, ConfigDict, Field

DB_PATH = Path(os.environ.get("DATABASE_PATH", "/data/agents.db"))
VECTOR_DIMENSIONS = int(os.environ.get("VECTOR_DIMENSIONS", "768"))
OLLAMA_BASE_URL = os.environ.get("OLLAMA_BASE_URL", "http://host.docker.internal:11434").rstrip("/")
OLLAMA_EMBED_MODEL = os.environ.get("OLLAMA_EMBED_MODEL", "nomic-embed-text")
ALLOWED_ORIGINS = [item.strip() for item in os.environ.get(
    "CORS_ORIGINS", "http://127.0.0.1:5173,http://localhost:5173,http://127.0.0.1:4173"
).split(",") if item.strip()]


def connect_db() -> sqlite3.Connection:
    # sqlite-vec's documented Python contract requires loading the extension on
    # every SQLite connection that queries vec0 tables. See:
    # https://github.com/asg017/sqlite-vec/blob/main/site/getting-started/installation.md
    # SQLite extension-loading controls are documented at:
    # https://docs.python.org/3/library/sqlite3.html#sqlite3.Connection.enable_load_extension
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(DB_PATH, timeout=8.0)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA foreign_keys = ON")
    connection.execute("PRAGMA busy_timeout = 8000")
    connection.execute("PRAGMA journal_mode = WAL")
    connection.execute("PRAGMA synchronous = NORMAL")
    connection.execute("PRAGMA temp_store = MEMORY")
    connection.enable_load_extension(True)
    try:
        sqlite_vec.load(connection)
    finally:
        connection.enable_load_extension(False)
    return connection


@contextmanager
def database_connection():
    """Commit/rollback transaction scope and always close the SQLite handle."""
    connection = connect_db()
    try:
        with connection:
            yield connection
    finally:
        connection.close()


def initialize_database() -> None:
    with database_connection() as db:
        db.execute("""CREATE TABLE IF NOT EXISTS schema_migrations (
            version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL, description TEXT NOT NULL
        )""")
        db.execute("""CREATE TABLE IF NOT EXISTS agents (
            id TEXT PRIMARY KEY, display_name TEXT NOT NULL, executable TEXT NOT NULL,
            installed INTEGER NOT NULL DEFAULT 0, first_seen_at TEXT NOT NULL,
            last_seen_at TEXT
        )""")
        db.execute("""CREATE TABLE IF NOT EXISTS usage_events (
            event_id TEXT PRIMARY KEY, agent_id TEXT NOT NULL, message_type TEXT NOT NULL DEFAULT 'assistant', session_id TEXT,
            provider_id TEXT, model_id TEXT, created_at TEXT NOT NULL,
            input_tokens INTEGER NOT NULL DEFAULT 0, output_tokens INTEGER NOT NULL DEFAULT 0,
            reasoning_tokens INTEGER NOT NULL DEFAULT 0, cache_read_tokens INTEGER NOT NULL DEFAULT 0,
            cache_write_tokens INTEGER NOT NULL DEFAULT 0, cost_usd REAL NOT NULL DEFAULT 0,
            assistant_message_count INTEGER NOT NULL DEFAULT 1,
            counter_reset_detected INTEGER NOT NULL DEFAULT 0,
            FOREIGN KEY(agent_id) REFERENCES agents(id)
        )""")
        usage_columns = {row["name"] for row in db.execute("PRAGMA table_info(usage_events)")}
        if "message_type" not in usage_columns:
            db.execute("ALTER TABLE usage_events ADD COLUMN message_type TEXT NOT NULL DEFAULT 'assistant'")
        if "assistant_message_count" not in usage_columns:
            db.execute("ALTER TABLE usage_events ADD COLUMN assistant_message_count INTEGER NOT NULL DEFAULT 1")
            db.execute("UPDATE usage_events SET assistant_message_count=CASE WHEN message_type='assistant' THEN 1 ELSE 0 END")
        if "counter_reset_detected" not in usage_columns:
            db.execute("ALTER TABLE usage_events ADD COLUMN counter_reset_detected INTEGER NOT NULL DEFAULT 0")
        db.execute("""CREATE TABLE IF NOT EXISTS session_usage_snapshots (
            session_id TEXT PRIMARY KEY, provider_id TEXT, model_id TEXT, observed_at TEXT NOT NULL,
            input_tokens INTEGER NOT NULL DEFAULT 0, output_tokens INTEGER NOT NULL DEFAULT 0,
            reasoning_tokens INTEGER NOT NULL DEFAULT 0, cache_read_tokens INTEGER NOT NULL DEFAULT 0,
            cache_write_tokens INTEGER NOT NULL DEFAULT 0, assistant_message_count INTEGER NOT NULL DEFAULT 0,
            cost_usd REAL NOT NULL DEFAULT 0, counter_reset_detected INTEGER NOT NULL DEFAULT 0
        )""")
        snapshot_columns = {row["name"] for row in db.execute("PRAGMA table_info(session_usage_snapshots)")}
        if "counter_reset_detected" not in snapshot_columns:
            db.execute("ALTER TABLE session_usage_snapshots ADD COLUMN counter_reset_detected INTEGER NOT NULL DEFAULT 0")
        db.execute("CREATE INDEX IF NOT EXISTS idx_session_snapshots_observed ON session_usage_snapshots(observed_at)")
        db.execute("INSERT OR IGNORE INTO schema_migrations(version,applied_at,description) VALUES (3,?,?)",
                   (datetime.now(timezone.utc).isoformat(), "Track cumulative OpenCode V2 session snapshots and ingest deltas"))
        db.execute("INSERT OR IGNORE INTO schema_migrations(version,applied_at,description) VALUES (4,?,?)",
                   (datetime.now(timezone.utc).isoformat(), "Record counter resets during cumulative session-delta ingestion"))
        db.execute("CREATE INDEX IF NOT EXISTS idx_usage_created ON usage_events(created_at)")
        db.execute("CREATE INDEX IF NOT EXISTS idx_usage_agent_model ON usage_events(agent_id, model_id)")
        db.execute("""CREATE TABLE IF NOT EXISTS app_meta (
            key TEXT PRIMARY KEY, value TEXT NOT NULL
        )""")
        configured_dimensions = db.execute("SELECT value FROM app_meta WHERE key='vector_dimensions'").fetchone()
        if configured_dimensions is None:
            db.execute("INSERT INTO app_meta(key,value) VALUES ('vector_dimensions',?)", (str(VECTOR_DIMENSIONS),))
        elif int(configured_dimensions["value"]) != VECTOR_DIMENSIONS:
            raise RuntimeError(
                f"Existing vector index uses {configured_dimensions['value']} dimensions; "
                f"configured value is {VECTOR_DIMENSIONS}. Back up and migrate the vector table before changing VECTOR_DIMENSIONS."
            )
        db.execute("""CREATE TABLE IF NOT EXISTS documents (
            id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, body TEXT NOT NULL,
            source TEXT NOT NULL DEFAULT 'manual', created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL, embedding_model TEXT, embedding_dimensions INTEGER
        )""")
        db.execute("""CREATE VIRTUAL TABLE IF NOT EXISTS documents_fts USING fts5(
            title, body, content='documents', content_rowid='id',
            tokenize='unicode61 remove_diacritics 2'
        )""")
        db.executescript("""
            CREATE TRIGGER IF NOT EXISTS documents_ai AFTER INSERT ON documents BEGIN
                INSERT INTO documents_fts(rowid, title, body) VALUES (new.id, new.title, new.body);
            END;
            CREATE TRIGGER IF NOT EXISTS documents_ad AFTER DELETE ON documents BEGIN
                INSERT INTO documents_fts(documents_fts, rowid, title, body)
                VALUES ('delete', old.id, old.title, old.body);
            END;
            CREATE TRIGGER IF NOT EXISTS documents_au AFTER UPDATE ON documents BEGIN
                INSERT INTO documents_fts(documents_fts, rowid, title, body)
                VALUES ('delete', old.id, old.title, old.body);
                INSERT INTO documents_fts(rowid, title, body) VALUES (new.id, new.title, new.body);
            END;
        """)
        # sqlite-vec is an explicit runtime dependency. Failing closed here is preferable
        # to advertising vector search when the extension is absent or incompatible.
        db.execute(f"""CREATE VIRTUAL TABLE IF NOT EXISTS documents_vec USING vec0(
            embedding float[{VECTOR_DIMENSIONS}]
        )""")
        db.execute("""INSERT OR IGNORE INTO schema_migrations(version, applied_at, description)
            VALUES (1, ?, 'Initial agent registry, usage ledger, FTS5 and sqlite-vec schema')""",
            (datetime.now(timezone.utc).isoformat(),))
        db.execute("""INSERT OR IGNORE INTO schema_migrations(version, applied_at, description)
            VALUES (2, ?, 'Add OpenCode message type for assistant and compaction accounting')""",
            (datetime.now(timezone.utc).isoformat(),))
        now = datetime.now(timezone.utc).isoformat()
        for agent_id, display_name, executable in (
            ("opencode", "OpenCode", "opencode"), ("claude", "Claude Code", "claude"),
            ("codex", "OpenAI Codex", "codex"), ("gemini", "Gemini CLI", "gemini"),
            ("pi", "Pi", "pi"), ("github-copilot", "GitHub Copilot CLI", "copilot"),
        ):
            db.execute("INSERT OR IGNORE INTO agents(id,display_name,executable,installed,first_seen_at) VALUES (?,?,?,?,?)",
                       (agent_id, display_name, executable, 0, now))
        integrity = db.execute("PRAGMA quick_check").fetchone()[0]
        if integrity != "ok":
            raise RuntimeError(f"SQLite quick_check failed during startup: {integrity}")
        db.execute("INSERT INTO app_meta(key,value) VALUES ('integrity_status',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (integrity,))
        db.execute("INSERT INTO app_meta(key,value) VALUES ('last_integrity_check_at',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (now,))


@asynccontextmanager
async def lifespan(_: FastAPI):
    initialize_database()
    yield


app = FastAPI(title="Fedora AI Agents Local API", version="1.0.0", lifespan=lifespan)
# Starlette CORS behavior and exact-origin allowlisting:
# https://www.starlette.io/middleware/#corsmiddleware
# CORS is not authentication; the Compose port is separately bound to loopback.
app.add_middleware(CORSMiddleware, allow_origins=ALLOWED_ORIGINS,
                   allow_credentials=False, allow_methods=["GET", "POST"],
                   allow_headers=["Content-Type", "Accept"])


class DocumentInput(BaseModel):
    title: str = Field(min_length=1, max_length=300)
    body: str = Field(min_length=1, max_length=100_000)
    source: str = Field(default="manual", max_length=300)
    embedding: list[float] | None = None


class SearchInput(BaseModel):
    query: str = Field(min_length=1, max_length=2000)
    limit: int = Field(default=8, ge=1, le=30)
    embedding: list[float] | None = None


def ollama_embedding(text: str) -> list[float] | None:
    """Ask a local Ollama server for an embedding; never send text to a cloud service."""
    request_body = json.dumps({"model": OLLAMA_EMBED_MODEL, "input": text}).encode()
    request = urllib.request.Request(
        f"{OLLAMA_BASE_URL}/api/embed", data=request_body,
        headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(request, timeout=12) as response:
            payload = json.loads(response.read().decode("utf-8"))
        vectors = payload.get("embeddings") or []
        return vectors[0] if vectors else None
    except (urllib.error.URLError, TimeoutError, ValueError, KeyError):
        return None


def validate_embedding(embedding: list[float] | None) -> list[float] | None:
    if embedding is None:
        return None
    if len(embedding) != VECTOR_DIMENSIONS:
        raise HTTPException(422, f"Embedding must contain exactly {VECTOR_DIMENSIONS} float values")
    return [float(value) for value in embedding]


def database_capabilities() -> dict[str, Any]:
    with database_connection() as db:
        version = db.execute("SELECT sqlite_version() AS version").fetchone()["version"]
        fts5 = db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='documents_fts'").fetchone() is not None
        vec = db.execute("SELECT 1 FROM sqlite_master WHERE name='documents_vec'").fetchone() is not None
        meta = {row["key"]: row["value"] for row in db.execute("SELECT key,value FROM app_meta WHERE key IN ('integrity_status','last_integrity_check_at')")}
    return {
        "sqlite_version": version, "fts5": fts5, "sqlite_vec": vec,
        "vector_dimensions": VECTOR_DIMENSIONS, "database_path": str(DB_PATH),
        "journal_mode": "WAL", "integrity": meta.get("integrity_status", "not-run"),
        "last_integrity_check_at": meta.get("last_integrity_check_at"),
    }


def registered_agents() -> list[dict[str, Any]]:
    with database_connection() as db:
        rows = db.execute("SELECT id,display_name,executable,installed,last_seen_at FROM agents ORDER BY display_name").fetchall()
    return [{"id": row["id"], "name": row["display_name"], "command": row["executable"],
             "installed": bool(row["installed"]), "last_seen_at": row["last_seen_at"],
             "usage_collector": row["id"] == "opencode"} for row in rows]


@app.get("/health")
def health():
    with database_connection() as db:
        db.execute("SELECT 1").fetchone()
    return {"status": "ok", "service": "fedora-ai-agents-api", "timestamp": datetime.now(timezone.utc).isoformat()}


@app.get("/api/admin/integrity")
def integrity_check():
    checked_at = datetime.now(timezone.utc).isoformat()
    with database_connection() as db:
        result = db.execute("PRAGMA quick_check").fetchone()[0]
        db.execute("INSERT INTO app_meta(key,value) VALUES ('integrity_status',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (result,))
        db.execute("INSERT INTO app_meta(key,value) VALUES ('last_integrity_check_at',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (checked_at,))
    if result != "ok":
        raise HTTPException(503, f"SQLite quick_check failed: {result}")
    return {"status": result, "checked_at": checked_at}


@app.get("/api/capabilities")
def capabilities():
    db = database_capabilities()
    with database_connection() as connection:
        meta = {row["key"]: row["value"] for row in connection.execute("SELECT key,value FROM app_meta WHERE key IN ('host_snapshot_at','opencode_status','opencode_error','opencode_aggregation_basis','opencode_timestamp_semantics')")}
    return {**db, "host_snapshot_at": meta.get("host_snapshot_at"),
            "opencode_status": meta.get("opencode_status", "waiting-for-host-collector"),
            "opencode_error": meta.get("opencode_error", ""),
            "opencode_aggregation_basis": meta.get("opencode_aggregation_basis", "none"),
            "opencode_timestamp_semantics": meta.get("opencode_timestamp_semantics", ""),
            "ollama": ollama_reachable(), "vector_search": db["sqlite_vec"],
            "fts5_search": db["fts5"], "collector_contract": "host-snapshot-v1"}


def ollama_reachable() -> bool:
    try:
        with urllib.request.urlopen(f"{OLLAMA_BASE_URL}/api/tags", timeout=1.5) as response:
            return response.status == 200
    except (urllib.error.URLError, TimeoutError):
        return False


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class HostAgentRecord(StrictModel):
    id: str = Field(min_length=1, max_length=64)
    display_name: str = Field(min_length=1, max_length=100)
    executable: str = Field(min_length=1, max_length=100)
    installed: bool


class OpenCodeUsageRecord(StrictModel):
    event_id: str = Field(min_length=1, max_length=256)
    session_id: str = Field(default="", max_length=256)
    provider_id: str | None = Field(default=None, max_length=128)
    model_id: str | None = Field(default=None, max_length=256)
    message_type: str = Field(default="assistant", pattern="^(assistant|compaction|session_aggregate)$")
    created_at: str = Field(min_length=1, max_length=64)
    assistant_message_count: int = Field(default=1, ge=0)
    input_tokens: int = Field(default=0, ge=0)
    output_tokens: int = Field(default=0, ge=0)
    reasoning_tokens: int = Field(default=0, ge=0)
    cache_read_tokens: int = Field(default=0, ge=0)
    cache_write_tokens: int = Field(default=0, ge=0)
    cost_usd: float = Field(default=0.0, ge=0, le=1e12)


class CollectorPrivacy(StrictModel):
    message_bodies_selected: bool
    credentials_selected: bool
    source_database_modified: bool


class OpenCodeSnapshot(StrictModel):
    schema_version: int
    agent: str
    status: str = Field(pattern="^(available|not-installed|database-unavailable|collector-error)$")
    stores: list[str] = Field(default_factory=list, max_length=4)
    records: list[OpenCodeUsageRecord] = Field(default_factory=list, max_length=100000)
    error: str | None = Field(default=None, max_length=500)
    aggregation_basis: str = Field(pattern="^(message-level|session-aggregate|mixed|none)$")
    timestamp_semantics: str = Field(max_length=500)
    privacy: CollectorPrivacy


class HostSnapshot(StrictModel):
    schema_version: int
    collected_at: str
    agents: list[HostAgentRecord]
    opencode: OpenCodeSnapshot


@app.get("/api/agents")
def agents():
    return {"agents": registered_agents()}


@app.get("/api/host-snapshot/status")
def host_snapshot_status():
    with database_connection() as db:
        meta = {row["key"]: row["value"] for row in db.execute("SELECT key,value FROM app_meta WHERE key IN ('host_snapshot_at','opencode_status','opencode_error','opencode_aggregation_basis','opencode_timestamp_semantics')")}
    return {"last_snapshot_at": meta.get("host_snapshot_at"),
            "opencode_status": meta.get("opencode_status", "waiting-for-host-collector"),
            "opencode_error": meta.get("opencode_error", ""),
            "opencode_aggregation_basis": meta.get("opencode_aggregation_basis", "none"),
            "opencode_timestamp_semantics": meta.get("opencode_timestamp_semantics", "")}


@app.post("/api/ingest/host-snapshot")
def ingest_host_snapshot(payload: HostSnapshot):
    if payload.schema_version != 1 or payload.opencode.schema_version != 1 or payload.opencode.agent != "opencode":
        raise HTTPException(422, "Unsupported host snapshot or collector schema version")
    allowed = {"opencode": "opencode", "claude": "claude", "codex": "codex",
               "gemini": "gemini", "pi": "pi", "github-copilot": "copilot"}
    received = {agent.id for agent in payload.agents}
    if len(payload.agents) != len(allowed) or received != set(allowed):
        raise HTTPException(422, "Host snapshot must include every registered agent exactly once")
    if any(agent.executable != allowed[agent.id] for agent in payload.agents):
        raise HTTPException(422, "Host snapshot executable does not match the fixed registry")
    opencode_installed = next(agent.installed for agent in payload.agents if agent.id == "opencode")
    if payload.opencode.status == "available" and not opencode_installed:
        raise HTTPException(422, "OpenCode usage cannot be available when its executable is not detected")
    if not opencode_installed and payload.opencode.status != "not-installed":
        raise HTTPException(422, "An absent OpenCode executable must use not-installed status")
    if opencode_installed and payload.opencode.status == "not-installed":
        raise HTTPException(422, "An installed OpenCode executable cannot use not-installed status")
    if len({item.event_id for item in payload.opencode.records}) != len(payload.opencode.records):
        raise HTTPException(422, "Host snapshot contains duplicate usage event IDs")
    if payload.opencode.privacy.message_bodies_selected or payload.opencode.privacy.credentials_selected or payload.opencode.privacy.source_database_modified:
        raise HTTPException(422, "Collector privacy contract violation: content/credentials selected or source database modified")
    if payload.opencode.status != "available" and payload.opencode.records:
        raise HTTPException(422, "A non-available OpenCode collector status cannot carry usage records")
    if any(store not in {"message", "session", "session_v2", "session_message"} for store in payload.opencode.stores):
        raise HTTPException(422, "Host snapshot contains an unsupported OpenCode usage store")
    if payload.opencode.status != "available" and payload.opencode.aggregation_basis != "none":
        raise HTTPException(422, "A non-available collector must declare aggregation_basis=none")
    if payload.opencode.status == "available" and payload.opencode.aggregation_basis == "none" and payload.opencode.records:
        raise HTTPException(422, "A snapshot with usage records must declare its aggregation basis")
    has_session_aggregates = any(item.message_type == "session_aggregate" for item in payload.opencode.records)
    has_message_events = any(item.message_type != "session_aggregate" for item in payload.opencode.records)
    if has_session_aggregates and payload.opencode.aggregation_basis not in {"session-aggregate", "mixed"}:
        raise HTTPException(422, "Session aggregate records require session-aggregate or mixed basis")
    if has_message_events and payload.opencode.aggregation_basis not in {"message-level", "mixed"}:
        raise HTTPException(422, "Message events require message-level or mixed basis")
    try:
        datetime.fromisoformat(payload.collected_at.replace("Z", "+00:00"))
        for item in payload.opencode.records:
            datetime.fromisoformat(item.created_at.replace("Z", "+00:00"))
    except ValueError as exc:
        raise HTTPException(422, "Host snapshot contains an invalid timestamp") from exc
    now = datetime.now(timezone.utc).isoformat()
    with database_connection() as db:
        before = db.total_changes
        for agent in payload.agents:
            db.execute("""INSERT INTO agents(id,display_name,executable,installed,first_seen_at,last_seen_at)
                VALUES (?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET
                display_name=excluded.display_name, executable=excluded.executable,
                installed=excluded.installed, last_seen_at=excluded.last_seen_at""",
                (agent.id, agent.display_name, agent.executable, int(agent.installed), now, now))
        for item in payload.opencode.records:
            if item.message_type == "session_aggregate":
                # V2 session counters are lifetime cumulative values. Convert
                # each host snapshot to a positive delta so repeated polls do
                # not add the same session totals twice.
                previous = db.execute("SELECT * FROM session_usage_snapshots WHERE session_id=?", (item.session_id,)).fetchone()
                observed_at = datetime.fromisoformat(payload.collected_at.replace("Z", "+00:00")).astimezone(timezone.utc).isoformat()
                if previous and previous["observed_at"] >= observed_at:
                    continue
                current = {
                    "input_tokens": item.input_tokens,
                    "output_tokens": item.output_tokens,
                    "reasoning_tokens": item.reasoning_tokens,
                    "cache_read_tokens": item.cache_read_tokens,
                    "cache_write_tokens": item.cache_write_tokens,
                    "assistant_message_count": item.assistant_message_count,
                    "cost_usd": item.cost_usd,
                }
                reset_detected = bool(previous and any(value < previous[key] for key, value in current.items()))
                delta = {}
                for key, value in current.items():
                    prior = previous[key] if previous else 0
                    # A reset is explicitly recorded. The new value is treated
                    # as the first delta of a fresh counter epoch, never negative.
                    delta[key] = value - prior if value >= prior else value
                if any(value > 0 for value in delta.values()) or reset_detected:
                    session_hash = hashlib.sha256(item.session_id.encode("utf-8")).hexdigest()[:20]
                    delta_event_id = f"session-delta:{session_hash}:{observed_at}"
                    db.execute("""INSERT OR IGNORE INTO usage_events(
                        event_id,agent_id,message_type,session_id,provider_id,model_id,created_at,
                        input_tokens,output_tokens,reasoning_tokens,cache_read_tokens,cache_write_tokens,
                        cost_usd,assistant_message_count,counter_reset_detected
                    ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                    (delta_event_id, "opencode", "session_delta", item.session_id,
                     item.provider_id, item.model_id, observed_at, delta["input_tokens"],
                     delta["output_tokens"], delta["reasoning_tokens"], delta["cache_read_tokens"],
                     delta["cache_write_tokens"], delta["cost_usd"], delta["assistant_message_count"],
                     int(reset_detected)))
                db.execute("""INSERT INTO session_usage_snapshots(
                    session_id,provider_id,model_id,observed_at,input_tokens,output_tokens,
                    reasoning_tokens,cache_read_tokens,cache_write_tokens,assistant_message_count,cost_usd,counter_reset_detected
                ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(session_id) DO UPDATE SET
                    provider_id=excluded.provider_id, model_id=excluded.model_id,
                    observed_at=excluded.observed_at, input_tokens=excluded.input_tokens,
                    output_tokens=excluded.output_tokens, reasoning_tokens=excluded.reasoning_tokens,
                    cache_read_tokens=excluded.cache_read_tokens, cache_write_tokens=excluded.cache_write_tokens,
                    assistant_message_count=excluded.assistant_message_count, cost_usd=excluded.cost_usd,
                    counter_reset_detected=excluded.counter_reset_detected
                """, (item.session_id, item.provider_id, item.model_id, observed_at,
                      item.input_tokens, item.output_tokens, item.reasoning_tokens,
                      item.cache_read_tokens, item.cache_write_tokens,
                      item.assistant_message_count, item.cost_usd, int(reset_detected)))
            else:
                db.execute("""INSERT OR IGNORE INTO usage_events(
                    event_id,agent_id,message_type,session_id,provider_id,model_id,created_at,
                    input_tokens,output_tokens,reasoning_tokens,cache_read_tokens,cache_write_tokens,
                    cost_usd,assistant_message_count
                ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                (item.event_id, "opencode", item.message_type, item.session_id, item.provider_id,
                 item.model_id, item.created_at, item.input_tokens, item.output_tokens,
                 item.reasoning_tokens, item.cache_read_tokens, item.cache_write_tokens,
                 item.cost_usd, item.assistant_message_count))
        imported = db.total_changes - before
        db.execute("INSERT INTO app_meta(key,value) VALUES ('host_snapshot_at',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (payload.collected_at,))
        db.execute("INSERT INTO app_meta(key,value) VALUES ('opencode_status',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (payload.opencode.status,))
        db.execute("INSERT INTO app_meta(key,value) VALUES ('opencode_error',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (payload.opencode.error or "",))
        db.execute("INSERT INTO app_meta(key,value) VALUES ('opencode_aggregation_basis',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (payload.opencode.aggregation_basis,))
        db.execute("INSERT INTO app_meta(key,value) VALUES ('opencode_timestamp_semantics',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (payload.opencode.timestamp_semantics,))
    return {"accepted": True, "agent_count": len(payload.agents),
            "observed_usage_events": len(payload.opencode.records),
            "imported_records_and_agent_updates": imported,
            "opencode_status": payload.opencode.status,
            "credentials_received": False, "message_bodies_received": False}


@app.get("/api/usage/summary")
def usage_summary():
    with database_connection() as db:
        totals = db.execute("""SELECT COALESCE(SUM(assistant_message_count),0) AS assistant_messages,
            COALESCE(SUM(input_tokens+output_tokens),0) AS input_output_tokens,
            COALESCE(SUM(reasoning_tokens),0) AS reasoning_tokens,
            COALESCE(SUM(cache_read_tokens),0) AS cache_read_tokens,
            COALESCE(SUM(cache_write_tokens),0) AS cache_write_tokens,
            COALESCE(SUM(cost_usd),0) AS cost_usd,
            COUNT(DISTINCT session_id) AS sessions, COUNT(*) AS usage_events,
            COALESCE(SUM(counter_reset_detected),0) AS counter_reset_events
            FROM usage_events WHERE agent_id='opencode'""").fetchone()
        start = (datetime.now(timezone.utc).date() - timedelta(days=6)).isoformat()
        rows = db.execute("""SELECT substr(created_at,1,10) AS day,
            SUM(input_tokens+output_tokens) AS input_output_tokens,
            SUM(reasoning_tokens) AS reasoning_tokens,
            SUM(cache_read_tokens) AS cache_read_tokens,
            SUM(cache_write_tokens) AS cache_write_tokens,
            SUM(cost_usd) AS cost_usd,
            SUM(assistant_message_count) AS assistant_messages,
            SUM(counter_reset_detected) AS counter_reset_events
            FROM usage_events WHERE agent_id='opencode' AND substr(created_at,1,10)>=?
            GROUP BY day ORDER BY day""", (start,)).fetchall()
    mapping = {row["day"]: dict(row) for row in rows}
    daily = []
    for offset in range(6, -1, -1):
        date_value = (datetime.now(timezone.utc).date() - timedelta(days=offset)).isoformat()
        row = mapping.get(date_value, {})
        daily.append({"day": (datetime.now(timezone.utc).date() - timedelta(days=offset)).strftime("%a"),
                      "date": date_value, "input_output_tokens": int(row.get("input_output_tokens") or 0),
                      "reasoning_tokens": int(row.get("reasoning_tokens") or 0),
                      "cache_read_tokens": int(row.get("cache_read_tokens") or 0),
                      "cache_write_tokens": int(row.get("cache_write_tokens") or 0),
                      "cost_usd": float(row.get("cost_usd") or 0),
                      "assistant_messages": int(row.get("assistant_messages") or 0),
                      "counter_reset_events": int(row.get("counter_reset_events") or 0)})
    return {**dict(totals), "daily": daily}


@app.post("/api/documents")
def add_document(payload: DocumentInput):
    embedding = validate_embedding(payload.embedding)
    if embedding is None:
        embedding = ollama_embedding(f"{payload.title}\n\n{payload.body}")
    if embedding is not None:
        embedding = validate_embedding(embedding)
    now = datetime.now(timezone.utc).isoformat()
    with database_connection() as db:
        cursor = db.execute("""INSERT INTO documents(title,body,source,created_at,updated_at,embedding_model,embedding_dimensions)
            VALUES (?,?,?,?,?,?,?)""", (payload.title, payload.body, payload.source, now, now,
            OLLAMA_EMBED_MODEL if embedding else None, len(embedding) if embedding else None))
        document_id = cursor.lastrowid
        if embedding is not None:
            db.execute("INSERT INTO documents_vec(rowid,embedding) VALUES (?,?)", (document_id, json.dumps(embedding)))
    return {"id": document_id, "indexed_fts5": True, "indexed_vector": embedding is not None,
            "vector_dimensions": len(embedding) if embedding else None}


@app.post("/api/search")
def search(payload: SearchInput):
    query_embedding = validate_embedding(payload.embedding) if payload.embedding is not None else ollama_embedding(payload.query)
    lexical: dict[int, dict[str, Any]] = {}
    with database_connection() as db:
        try:
            rows = db.execute("""SELECT d.id,d.title,d.body,d.source,bm25(documents_fts) AS rank
                FROM documents_fts JOIN documents d ON d.id=documents_fts.rowid
                WHERE documents_fts MATCH ? ORDER BY rank LIMIT ?""", (payload.query, payload.limit)).fetchall()
            for row in rows:
                lexical[int(row["id"])] = {"id": int(row["id"]), "title": row["title"],
                    "excerpt": row["body"][:260], "source": row["source"],
                    "lexical_rank": float(row["rank"]), "score": 0.0}
        except sqlite3.OperationalError:
            # Invalid FTS syntax is not interpolated into SQL; return an empty lexical set.
            lexical = {}
        semantic: dict[int, float] = {}
        if query_embedding is not None:
            try:
                matches = db.execute("""SELECT rowid,distance FROM documents_vec
                    WHERE embedding MATCH ? ORDER BY distance LIMIT ?""",
                    (json.dumps(query_embedding), payload.limit)).fetchall()
                semantic = {int(row["rowid"]): float(row["distance"]) for row in matches}
            except sqlite3.Error as exc:
                raise HTTPException(503, f"Vector search failed: {exc}") from exc
        for doc_id, distance in semantic.items():
            if doc_id not in lexical:
                row = db.execute("SELECT id,title,body,source FROM documents WHERE id=?", (doc_id,)).fetchone()
                if row:
                    lexical[doc_id] = {"id": int(row["id"]), "title": row["title"],
                        "excerpt": row["body"][:260], "source": row["source"],
                        "lexical_rank": None, "score": 0.0}
            if doc_id in lexical:
                lexical[doc_id]["vector_distance"] = distance
                lexical[doc_id]["score"] += 1.0 / (1.0 + max(distance, 0.0))
        for item in lexical.values():
            if item.get("lexical_rank") is not None:
                item["score"] += 1.0 / (1.0 + abs(item["lexical_rank"]))
            item["score_label"] = f"hybrid {item['score']:.3f}"
        results = sorted(lexical.values(), key=lambda item: item["score"], reverse=True)[:payload.limit]
    return {"mode": "hybrid" if query_embedding is not None else "lexical-only",
            "vector_available": query_embedding is not None, "results": results}


@app.post("/api/admin/backup")
def backup_database():
    # SQLite's backup API includes committed WAL content; copying only agents.db is unsafe.
    destination = DB_PATH.with_name(f"{DB_PATH.stem}-backup-{int(time.time())}.db")
    with database_connection() as source:
        target = sqlite3.connect(destination)
        try:
            source.backup(target)
            check = target.execute("PRAGMA integrity_check").fetchone()[0]
            if check != "ok":
                raise HTTPException(500, f"Backup integrity check failed: {check}")
        finally:
            target.close()
    return {"backup_path": str(destination), "integrity": "ok"}
