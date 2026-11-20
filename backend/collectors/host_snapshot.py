"""Host-side agent detection and sanitized usage snapshot producer.

Run as the logged-in Fedora user, not inside Docker:
    PYTHONPATH=backend python3 -m collectors.host_snapshot

The output contains executable-presence metadata and normalized OpenCode usage
records only. It never serializes credentials, prompts, message bodies or tool output.
"""
from __future__ import annotations

import json
import shutil
from datetime import datetime, timezone

from collectors.opencode import collect_opencode_usage

SCHEMA_VERSION = 1
AGENT_REGISTRY = (
    ("opencode", "OpenCode", "opencode"),
    ("claude", "Claude Code", "claude"),
    ("codex", "OpenAI Codex", "codex"),
    ("gemini", "Gemini CLI", "gemini"),
    ("pi", "Pi", "pi"),
    ("github-copilot", "GitHub Copilot CLI", "copilot"),
)


def build_host_snapshot() -> dict:
    agents = [
        {"id": agent_id, "display_name": display_name, "executable": executable,
         "installed": bool(shutil.which(executable))}
        for agent_id, display_name, executable in AGENT_REGISTRY
    ]
    opencode_installed = next(agent["installed"] for agent in agents if agent["id"] == "opencode")
    status = "not-installed"
    records = []
    stores = []
    aggregation_basis = "none"
    timestamp_semantics = "No OpenCode usage data collected."
    if opencode_installed:
        try:
            collected = collect_opencode_usage()
            status = "available"
            records = collected["records"]
            stores = collected["stores"]
            aggregation_basis = collected.get("aggregation_basis", "none")
            timestamp_semantics = collected.get("timestamp_semantics", "Collector did not report timestamp semantics.")
        except FileNotFoundError:
            status = "database-unavailable"
            error = None
        except Exception as exc:
            status = "collector-error"
            error = str(exc)[:500]
        else:
            error = None
    else:
        error = None

    return {
        "schema_version": SCHEMA_VERSION,
        "collected_at": datetime.now(timezone.utc).isoformat(),
        "agents": agents,
        "opencode": {
            "schema_version": 1, "agent": "opencode", "status": status,
            "stores": stores, "records": records, "error": error,
            "aggregation_basis": aggregation_basis,
            "timestamp_semantics": timestamp_semantics,
            "privacy": {"message_bodies_selected": False,
                        "credentials_selected": False,
                        "source_database_modified": False},
        },
    }


def main() -> int:
    try:
        print(json.dumps(build_host_snapshot(), ensure_ascii=False, separators=(",", ":")))
        return 0
    except Exception as exc:
        print(json.dumps({"schema_version": SCHEMA_VERSION, "error": str(exc)}), file=__import__("sys").stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
