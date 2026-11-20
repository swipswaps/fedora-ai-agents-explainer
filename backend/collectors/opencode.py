"""Read-only OpenCode usage adapter for V1 and V2 SQLite layouts.

Schema evidence is checked against OpenCode's generated database schema:
https://github.com/anomalyco/opencode/blob/dev/packages/core/src/database/schema.gen.ts
The collector strategy is informed by Omarchy's shared OpenCode reader:
https://github.com/omacom/omarchy/blob/quattro/shell/plugins/agents/collectors.py
These are implementation references, not a promise that upstream schemas never change.

V1 stores per-message token/cost metadata in message.data JSON.
V2 assistant rows in session_message.data also contain per-message model,
cost, token and time metadata. session_v2 (or newer session) stores cumulative
counters, used only as a fallback when per-message usage is absent.

The adapter never reads message/part content for V2, and it never queries
credential/account tables. V1 JSON is projected by SQLite into usage metadata;
body fields are not returned to Python or transmitted.
"""
from __future__ import annotations

import json
import os
import sqlite3
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

DEFAULT_DATABASE = Path(os.environ.get(
    "OPENCODE_DB_PATH",
    str(Path(os.environ.get("XDG_DATA_HOME", str(Path.home() / ".local/share"))) / "opencode" / "opencode.db"),
))
MAX_USAGE_EVENTS = 100000
MAX_MESSAGE_ROWS = 1000000
USAGE_COLUMNS = (
    "tokens_input", "tokens_output", "tokens_reasoning",
    "tokens_cache_read", "tokens_cache_write", "cost",
)
ALLOWED_FUNCTIONS = {"json_valid", "json_extract"}


def _timestamp_seconds(value: Any) -> float | None:
    if value is None:
        return None
    try:
        if isinstance(value, str) and not value.strip().replace(".", "", 1).isdigit():
            parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
            if parsed.tzinfo is None:
                parsed = parsed.replace(tzinfo=timezone.utc)
            return parsed.timestamp()
        number = float(value)
        return number / 1000.0 if number > 100000000000 else number
    except (TypeError, ValueError, OverflowError):
        return None


def _iso_timestamp(value: Any) -> str | None:
    seconds = _timestamp_seconds(value)
    if seconds is None:
        return None
    try:
        return datetime.fromtimestamp(seconds, timezone.utc).isoformat()
    except (ValueError, OverflowError, OSError):
        return None


def _integer(value: Any) -> int:
    try:
        return max(0, int(value or 0))
    except (TypeError, ValueError, OverflowError):
        return 0


def _float(value: Any) -> float:
    try:
        number = float(value or 0)
        return max(0.0, number) if number == number and number not in (float("inf"), float("-inf")) else 0.0
    except (TypeError, ValueError, OverflowError):
        return 0.0


def _model_identifiers(value: Any) -> tuple[str | None, str | None]:
    try:
        model = json.loads(value) if isinstance(value, str) else value
    except (TypeError, ValueError, json.JSONDecodeError):
        model = None
    if not isinstance(model, dict):
        return None, None
    provider = model.get("providerID") or model.get("providerId")
    model_id = model.get("id") or model.get("modelID") or model.get("modelId")
    return (str(provider)[:128] if provider else None,
            str(model_id)[:256] if model_id else None)


def _table_columns(connection: sqlite3.Connection, table: str) -> set[str]:
    # Table names come only from the fixed allowlist below, never from user input.
    return {str(row["name"]) for row in connection.execute(f'PRAGMA table_info("{table}")')}


def _usage_record(
    *, event_id: str, session_id: str, provider_id: str | None, model_id: str | None,
    message_type: str, created_at: str, input_tokens: Any, output_tokens: Any,
    reasoning_tokens: Any, cache_read_tokens: Any, cache_write_tokens: Any,
    cost_usd: Any, assistant_message_count: int,
) -> dict[str, Any]:
    return {
        "event_id": event_id,
        "session_id": session_id,
        "provider_id": provider_id,
        "model_id": model_id,
        "message_type": message_type,
        "created_at": created_at,
        "input_tokens": _integer(input_tokens),
        "output_tokens": _integer(output_tokens),
        "reasoning_tokens": _integer(reasoning_tokens),
        "cache_read_tokens": _integer(cache_read_tokens),
        "cache_write_tokens": _integer(cache_write_tokens),
        "cost_usd": _float(cost_usd),
        "assistant_message_count": max(0, int(assistant_message_count)),
    }


def collect_opencode_usage(database_path: str | Path = DEFAULT_DATABASE) -> dict[str, Any]:
    """Return a schema-versioned, content-free usage projection from OpenCode."""
    path = Path(database_path).expanduser()
    if not path.is_file():
        raise FileNotFoundError(f"OpenCode database not found: {path}")

    # URI mode=ro plus query_only and an authorizer are three independent
    # restrictions. No checkpoint, migration, VACUUM, or write statement runs.
    uri = path.resolve().as_uri() + "?mode=ro"
    source = sqlite3.connect(uri, uri=True, timeout=3.0)
    source.row_factory = sqlite3.Row
    try:
        source.execute("PRAGMA query_only=ON")
        tables = {str(row[0]) for row in source.execute(
            "SELECT name FROM sqlite_master WHERE type='table'")}
        relevant = {"session", "session_v2", "message", "session_message"}
        if not (tables & relevant):
            raise RuntimeError("Unsupported OpenCode schema: no recognized session/message tables")

        allowed_reads = {
            "sqlite_master": {"name", "type"},
            "session": {"id", "model", "cost", "tokens_input", "tokens_output",
                        "tokens_reasoning", "tokens_cache_read", "tokens_cache_write",
                        "time_created", "time_updated"},
            "session_v2": {"id", "model", "cost", "tokens_input", "tokens_output",
                           "tokens_reasoning", "tokens_cache_read", "tokens_cache_write",
                           "time_created", "time_updated"},
            "message": {"id", "session_id", "data", "time_created"},
            # V2 data is read only through JSON1 projections; the raw JSON
            # column is never selected into Python or returned to the API.
            "session_message": {"id", "session_id", "type", "data", "seq", "time_created"},
        }

        def authorize(action: int, arg1: str | None, arg2: str | None,
                      database_name: str | None, trigger_name: str | None) -> int:
            if action == sqlite3.SQLITE_SELECT:
                return sqlite3.SQLITE_OK
            if action == sqlite3.SQLITE_READ:
                table_name, column_name = str(arg1 or ""), str(arg2 or "")
                if column_name in allowed_reads.get(table_name, set()):
                    return sqlite3.SQLITE_OK
                return sqlite3.SQLITE_DENY
            if action == sqlite3.SQLITE_FUNCTION:
                function_name = str(arg2 or arg1 or "").lower()
                return sqlite3.SQLITE_OK if function_name in ALLOWED_FUNCTIONS else sqlite3.SQLITE_DENY
            if action == sqlite3.SQLITE_PRAGMA:
                pragma_name, pragma_argument = str(arg1 or "").lower(), str(arg2 or "")
                if pragma_name == "table_info" and pragma_argument in relevant:
                    return sqlite3.SQLITE_OK
                return sqlite3.SQLITE_DENY
            return sqlite3.SQLITE_DENY

        source.set_authorizer(authorize)
        columns = {table: _table_columns(source, table) for table in relevant if table in tables}
        records: list[dict[str, Any]] = []
        seen_ids: set[str] = set()
        session_created: dict[str, float] = {}

        # Session creation timestamps are used only to reject copied pre-fork
        # legacy messages. They are metadata, not transcript content.
        for table in ("session", "session_v2"):
            if table in columns and {"id", "time_created"}.issubset(columns[table]):
                for row in source.execute(f'SELECT id,time_created FROM "{table}"'):
                    created = _timestamp_seconds(row["time_created"])
                    if created is not None:
                        session_created[str(row["id"])] = created

        # V2 message rows are inspected only for session_id and type. The data
        # column (which contains content arrays and tool output) is never read.
        v2_message_counts: dict[str, int] = {}
        if "session_message" in columns and not {"session_id", "type"}.issubset(columns["session_message"]):
            raise RuntimeError("OpenCode V2 session_message schema is missing session_id/type columns")
        if "session_message" in columns:
            row_count = 0
            for row in source.execute("SELECT session_id,type FROM session_message"):
                row_count += 1
                if row_count > MAX_MESSAGE_ROWS:
                    raise RuntimeError(f"OpenCode V2 message index exceeds the {MAX_MESSAGE_ROWS:,}-row safety cap")
                session_id = str(row["session_id"])
                v2_message_counts.setdefault(session_id, 0)
                if row["type"] == "assistant":
                    v2_message_counts[session_id] += 1
        v2_session_ids = set(v2_message_counts)
        v2_message_sessions: set[str] = set()
        message_level_sessions: set[str] = set()
        stores: list[str] = []

        # OpenCode V2 assistant rows retain per-message usage metadata in data.
        # JSON1 projects only model/tokens/cost/time; content and tool output are
        # never selected as a result column or returned to Python.
        if "session_message" in columns and {"id", "session_id", "type", "data"}.issubset(columns["session_message"]):
            row_time = "m.time_created" if "time_created" in columns["session_message"] else "NULL"
            v2_query = f"""
                SELECT m.id AS id, m.session_id AS session_id, m.type AS row_type,
                    {row_time} AS row_time,
                    CASE WHEN json_valid(m.data) THEN json_extract(m.data,'$.model.providerID') END AS provider_id,
                    CASE WHEN json_valid(m.data) THEN json_extract(m.data,'$.model.id') END AS model_id,
                    CASE WHEN json_valid(m.data) THEN json_extract(m.data,'$.time.created') END AS message_time,
                    CASE WHEN json_valid(m.data) THEN json_extract(m.data,'$.tokens.input') END AS input_tokens,
                    CASE WHEN json_valid(m.data) THEN json_extract(m.data,'$.tokens.output') END AS output_tokens,
                    CASE WHEN json_valid(m.data) THEN json_extract(m.data,'$.tokens.reasoning') END AS reasoning_tokens,
                    CASE WHEN json_valid(m.data) THEN json_extract(m.data,'$.tokens.cache.read') END AS cache_read_tokens,
                    CASE WHEN json_valid(m.data) THEN json_extract(m.data,'$.tokens.cache.write') END AS cache_write_tokens,
                    CASE WHEN json_valid(m.data) THEN json_extract(m.data,'$.cost') END AS cost_usd
                FROM session_message AS m WHERE m.type='assistant'
            """
            row_count = 0
            for row in source.execute(v2_query):
                row_count += 1
                if row_count > MAX_MESSAGE_ROWS:
                    raise RuntimeError(f"OpenCode V2 assistant scan exceeds the {MAX_MESSAGE_ROWS:,}-row safety cap")
                values = [row["input_tokens"], row["output_tokens"], row["reasoning_tokens"],
                          row["cache_read_tokens"], row["cache_write_tokens"], row["cost_usd"]]
                if not any(_float(value) > 0 for value in values):
                    continue
                session_id = str(row["session_id"])
                message_id = str(row["id"])
                event_id = f"message:{message_id}"
                if event_id in seen_ids:
                    continue
                message_seconds = _timestamp_seconds(row["message_time"] or row["row_time"])
                session_seconds = session_created.get(session_id)
                if message_seconds is None or (session_seconds is not None and message_seconds < session_seconds):
                    # A forked session can expose inherited history. A message
                    # timestamp before the child session's creation is not new
                    # usage attributable to that child.
                    continue
                created_at = _iso_timestamp(message_seconds)
                if created_at is None:
                    continue
                seen_ids.add(event_id)
                v2_message_sessions.add(session_id)
                message_level_sessions.add(session_id)
                records.append(_usage_record(
                    event_id=event_id, session_id=session_id,
                    provider_id=str(row["provider_id"])[:128] if row["provider_id"] else None,
                    model_id=str(row["model_id"])[:256] if row["model_id"] else None,
                    message_type="assistant", created_at=created_at,
                    input_tokens=row["input_tokens"], output_tokens=row["output_tokens"],
                    reasoning_tokens=row["reasoning_tokens"], cache_read_tokens=row["cache_read_tokens"],
                    cache_write_tokens=row["cache_write_tokens"], cost_usd=row["cost_usd"],
                    assistant_message_count=1,
                ))
                if len(records) > MAX_USAGE_EVENTS:
                    raise RuntimeError(f"OpenCode usage scan exceeds the {MAX_USAGE_EVENTS:,}-event safety cap")
            if v2_message_sessions:
                stores.append("session_message")

        def read_session_aggregates(table: str, include_ids: set[str] | None = None,
                                    exclude_ids: set[str] | None = None,
                                    strict: bool = False) -> set[str]:
            table_columns = columns.get(table, set())
            if not {"id", *USAGE_COLUMNS}.issubset(table_columns):
                if strict:
                    missing = sorted({"id", *USAGE_COLUMNS} - table_columns)
                    raise RuntimeError(f"OpenCode {table} usage schema is missing required columns: {missing}")
                return set()
            selected = ["id"]
            for column in ("model", "cost", "tokens_input", "tokens_output", "tokens_reasoning",
                           "tokens_cache_read", "tokens_cache_write", "time_created", "time_updated"):
                selected.append(f'"{column}"' if column in table_columns else f'NULL AS "{column}"')
            sql = f'SELECT {",".join(selected)} FROM "{table}"'
            added_sessions: set[str] = set()
            for row in source.execute(sql):
                session_id = str(row["id"])
                if include_ids is not None and session_id not in include_ids:
                    continue
                if exclude_ids is not None and session_id in exclude_ids:
                    continue
                values = [row["tokens_input"], row["tokens_output"], row["tokens_reasoning"],
                          row["tokens_cache_read"], row["tokens_cache_write"], row["cost"]]
                if not any(_float(value) > 0 for value in values):
                    continue
                created_at = _iso_timestamp(row["time_updated"] or row["time_created"])
                if created_at is None:
                    continue
                provider_id, model_id = _model_identifiers(row["model"])
                event_id = f"session-aggregate:{table}:{session_id}"
                if event_id in seen_ids:
                    continue
                seen_ids.add(event_id)
                records.append(_usage_record(
                    event_id=event_id, session_id=session_id, provider_id=provider_id, model_id=model_id,
                    message_type="session_aggregate", created_at=created_at,
                    input_tokens=row["tokens_input"], output_tokens=row["tokens_output"],
                    reasoning_tokens=row["tokens_reasoning"], cache_read_tokens=row["tokens_cache_read"],
                    cache_write_tokens=row["tokens_cache_write"], cost_usd=row["cost"],
                    assistant_message_count=v2_message_counts.get(session_id, 0),
                ))
                added_sessions.add(session_id)
                if len(records) > MAX_USAGE_EVENTS:
                    raise RuntimeError(f"OpenCode usage scan exceeds the {MAX_USAGE_EVENTS:,}-event safety cap")
            return added_sessions

        aggregate_sessions: set[str] = set()
        # V2 session aggregates are a fallback only when per-message usage
        # counters are absent for that session. The API differences successive
        # cumulative snapshots to avoid counting lifetime totals repeatedly.
        if "session_v2" in columns:
            aggregate_sessions |= read_session_aggregates(
                "session_v2", exclude_ids=v2_message_sessions, strict=True)
            if aggregate_sessions:
                stores.append("session_v2")
        elif "session" in columns and v2_session_ids:
            aggregate_sessions |= read_session_aggregates(
                "session", include_ids=v2_session_ids - v2_message_sessions, strict=True)
            if aggregate_sessions:
                stores.append("session")

        # V1 stores one usage-bearing assistant record per message. Exclude
        # sessions represented by the V2 message projection to prevent double
        # counting if a database contains both schema families.
        legacy_message_sessions: set[str] = set()
        if "message" in columns and {"id", "session_id", "data"}.issubset(columns["message"]):
            time_expression = 'm.time_created' if "time_created" in columns["message"] else "NULL"
            query = f"""
                SELECT m.id AS id, m.session_id AS session_id, {time_expression} AS row_time,
                    CASE WHEN json_valid(m.data) THEN json_extract(m.data,'$.role') END AS role,
                    CASE WHEN json_valid(m.data) THEN json_extract(m.data,'$.providerID') END AS provider_id,
                    CASE WHEN json_valid(m.data) THEN
                        CASE WHEN json_extract(m.data,'$.modelID') IS NOT NULL
                             THEN json_extract(m.data,'$.modelID')
                             ELSE json_extract(m.data,'$.model.modelID') END END AS model_id,
                    CASE WHEN json_valid(m.data) THEN json_extract(m.data,'$.time.created') END AS message_time,
                    CASE WHEN json_valid(m.data) THEN json_extract(m.data,'$.tokens.input') END AS input_tokens,
                    CASE WHEN json_valid(m.data) THEN json_extract(m.data,'$.tokens.output') END AS output_tokens,
                    CASE WHEN json_valid(m.data) THEN json_extract(m.data,'$.tokens.reasoning') END AS reasoning_tokens,
                    CASE WHEN json_valid(m.data) THEN json_extract(m.data,'$.tokens.cache.read') END AS cache_read_tokens,
                    CASE WHEN json_valid(m.data) THEN json_extract(m.data,'$.tokens.cache.write') END AS cache_write_tokens,
                    CASE WHEN json_valid(m.data) THEN json_extract(m.data,'$.cost') END AS cost_usd
                FROM message AS m
            """
            row_count = 0
            for row in source.execute(query):
                row_count += 1
                if row_count > MAX_MESSAGE_ROWS:
                    raise RuntimeError(f"OpenCode legacy message scan exceeds the {MAX_MESSAGE_ROWS:,}-row safety cap")
                session_id = str(row["session_id"])
                if session_id in v2_session_ids or row["role"] != "assistant":
                    continue
                message_seconds = _timestamp_seconds(row["message_time"] or row["row_time"])
                session_seconds = session_created.get(session_id)
                if message_seconds is None:
                    continue
                if session_seconds is not None and message_seconds < session_seconds:
                    continue
                values = [row["input_tokens"], row["output_tokens"], row["reasoning_tokens"],
                          row["cache_read_tokens"], row["cache_write_tokens"], row["cost_usd"]]
                if not any(_float(value) > 0 for value in values):
                    continue
                event_id = f"message:{row['id']}"
                if event_id in seen_ids:
                    continue
                created_at = _iso_timestamp(message_seconds)
                if created_at is None:
                    continue
                seen_ids.add(event_id)
                records.append(_usage_record(
                    event_id=event_id, session_id=session_id,
                    provider_id=str(row["provider_id"])[:128] if row["provider_id"] else None,
                    model_id=str(row["model_id"])[:256] if row["model_id"] else None,
                    message_type="assistant", created_at=created_at,
                    input_tokens=row["input_tokens"], output_tokens=row["output_tokens"],
                    reasoning_tokens=row["reasoning_tokens"], cache_read_tokens=row["cache_read_tokens"],
                    cache_write_tokens=row["cache_write_tokens"], cost_usd=row["cost_usd"],
                    assistant_message_count=1,
                ))
                legacy_message_sessions.add(session_id)
                message_level_sessions.add(session_id)
                if len(records) > MAX_USAGE_EVENTS:
                    raise RuntimeError(f"OpenCode usage scan exceeds the {MAX_USAGE_EVENTS:,}-event safety cap")
            if legacy_message_sessions:
                stores.append("message")

        # Newer databases may have session aggregates plus a V2 message table,
        # while V1-only databases can have aggregate columns but incomplete
        # per-message JSON. Use session aggregates only for sessions that did
        # not already contribute message-level usage.
        if "session" in columns and "session" not in stores:
            if "session_v2" in columns:
                include_ids = None
                exclude_ids = v2_session_ids | legacy_message_sessions | v2_message_sessions | aggregate_sessions
            elif v2_session_ids:
                include_ids = v2_session_ids - v2_message_sessions
                exclude_ids = legacy_message_sessions
            else:
                include_ids = None
                exclude_ids = legacy_message_sessions | message_level_sessions
            fallback_sessions = read_session_aggregates("session", include_ids, exclude_ids)
            if fallback_sessions:
                aggregate_sessions |= fallback_sessions
                stores.append("session")

        if "session_message" in columns and v2_message_counts and "session_message" not in stores:
            stores.append("session_message")
        if not records and not stores:
            raise RuntimeError("OpenCode database exists, but no supported usage schema was detected")
        basis = "mixed" if aggregate_sessions and message_level_sessions else (
            "session-aggregate" if aggregate_sessions else "message-level" if message_level_sessions else "none")
        return {
            "collector": "opencode-sqlite-host-v2",
            "schema_version": 1,
            "agent": "opencode",
            "status": "ok",
            "database": str(path),
            "stores": sorted(set(stores)),
            "aggregation_basis": basis,
            "timestamp_semantics": "V1/V2 message events use assistant-message creation times; V2 session-aggregate fallbacks are differenced by the API at host snapshot observation times.",
            "records": records,
            "privacy": {
                "message_bodies_selected": False,
                "credentials_selected": False,
                "source_database_modified": False,
            },
        }
    finally:
        source.close()


def main() -> int:
    try:
        envelope = collect_opencode_usage()
    except Exception as exc:
        print(json.dumps({"schema_version": 1, "agent": "opencode", "status": "error", "error": str(exc)}))
        return 1
    print(json.dumps({key: value for key, value in envelope.items() if key != "records"}, ensure_ascii=False))
    for record in envelope["records"]:
        print(json.dumps(record, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
