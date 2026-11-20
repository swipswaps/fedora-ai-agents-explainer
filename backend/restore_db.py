"""Validate and atomically restore a Fedora AI Agents SQLite backup.

SQLite online backup and transaction semantics:
https://www.sqlite.org/backup.html
Python's atomic os.replace filesystem operation:
https://docs.python.org/3/library/os.html#os.replace
This utility runs inside the API image as its unprivileged application UID.
Input arrives on stdin so the host backup file is not mounted into the container.
It uses SQLite's online backup API, validates FTS5/sqlite-vec, preserves the
pre-restore database and WAL sidecars, and replaces agents.db atomically.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path

import sqlite_vec

DATA_DIR = Path("/data")
DB_PATH = DATA_DIR / "agents.db"
BACKUP_DIR = DATA_DIR / "backups"
REQUIRED_TABLES = {
    "agents", "usage_events", "app_meta", "documents",
    "documents_fts", "documents_vec", "schema_migrations",
}


def timestamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")


def connect_database(path: Path, readonly: bool = False) -> sqlite3.Connection:
    if readonly:
        connection = sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True, timeout=10)
    else:
        connection = sqlite3.connect(path, timeout=10)
    connection.row_factory = sqlite3.Row
    connection.enable_load_extension(True)
    try:
        sqlite_vec.load(connection)
    finally:
        connection.enable_load_extension(False)
    return connection


def validate_database(path: Path) -> dict:
    if not path.is_file() or path.stat().st_size < 100:
        raise RuntimeError(f"Database candidate is missing or too small: {path}")
    with path.open("rb") as source:
        if source.read(16) != b"SQLite format 3\x00":
            raise RuntimeError("Backup does not have a valid SQLite database header")
    connection = connect_database(path, readonly=True)
    try:
        integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
        if integrity != "ok":
            raise RuntimeError(f"SQLite integrity_check failed: {integrity}")
        foreign_key_errors = connection.execute("PRAGMA foreign_key_check").fetchmany(10)
        if foreign_key_errors:
            raise RuntimeError(f"SQLite foreign_key_check found violations: {[tuple(row) for row in foreign_key_errors]}")
        tables = {row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        missing = sorted(REQUIRED_TABLES - tables)
        if missing:
            raise RuntimeError(f"Backup is missing required application tables: {missing}")
        fts_rows = int(connection.execute("SELECT count(*) FROM documents_fts").fetchone()[0])
        vector_rows = int(connection.execute("SELECT count(*) FROM documents_vec").fetchone()[0])
        usage_rows = int(connection.execute("SELECT count(*) FROM usage_events").fetchone()[0])
        return {"integrity": integrity, "fts_rows": fts_rows,
                "vector_rows": vector_rows, "usage_rows": usage_rows,
                "sqlite_version": sqlite3.sqlite_version}
    finally:
        connection.close()


def online_backup(source_path: Path, target_path: Path) -> None:
    source = connect_database(source_path, readonly=True)
    target = connect_database(target_path)
    try:
        source.backup(target, pages=256, sleep=0.05)
        target.commit()
    finally:
        target.close()
        source.close()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while True:
            chunk = source.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def read_stdin_backup(candidate: Path) -> None:
    total = 0
    with candidate.open("xb") as destination:
        while True:
            chunk = sys.stdin.buffer.read(1024 * 1024)
            if not chunk:
                break
            destination.write(chunk)
            total += len(chunk)
        destination.flush()
        os.fsync(destination.fileno())
    os.chmod(candidate, 0o600)
    if total < 100:
        raise RuntimeError("No valid backup bytes arrived on standard input")


def restore(source_path: Path, skip_pre_restore_backup: bool = False) -> dict:
    BACKUP_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(BACKUP_DIR, 0o700)
    stamp = timestamp()
    source_info = validate_database(source_path)

    # Preserve the current DB with SQLite's backup API before replacing it.
    pre_restore = BACKUP_DIR / f"agents-pre-restore-{stamp}.db"
    if DB_PATH.exists() and not skip_pre_restore_backup:
        online_backup(DB_PATH, pre_restore)
        os.chmod(pre_restore, 0o600)
        try:
            pre_restore_info = validate_database(pre_restore)
        except Exception as exc:
            # Preserve the exact pre-restore bytes even if the current DB has
            # a schema issue; rollback must not depend on a clean schema.
            pre_restore_info = {"integrity": "not-validated", "error": str(exc)[:300]}
    else:
        pre_restore = None
        pre_restore_info = None

    restore_temp = DATA_DIR / f".agents-restore-{stamp}.db"
    online_backup(source_path, restore_temp)
    restored_info = validate_database(restore_temp)

    # All SQLite connections are closed before touching WAL/SHM sidecars.
    # Preserve rather than delete them; the new DB must never inherit a stale WAL.
    if DB_PATH.exists():
        for suffix in ("-wal", "-shm"):
            sidecar = Path(str(DB_PATH) + suffix)
            if sidecar.exists():
                preserved = BACKUP_DIR / f"agents-sidecar-before-restore-{stamp}.db{suffix}"
                os.replace(sidecar, preserved)

    os.chmod(restore_temp, 0o600)
    os.replace(restore_temp, DB_PATH)
    directory_fd = os.open(DATA_DIR, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)

    try:
        final_info = validate_database(DB_PATH)
    except Exception:
        # Best-effort automatic rollback from the verified pre-restore copy.
        if pre_restore is not None:
            rollback_temp = DATA_DIR / f".agents-rollback-{stamp}.db"
            online_backup(pre_restore, rollback_temp)
            os.chmod(rollback_temp, 0o600)
            os.replace(rollback_temp, DB_PATH)
        raise

    source_hash = sha256_file(source_path)
    return {
        "status": "restored",
        "database_path": str(DB_PATH),
        "restored_from": str(source_path),
        "source_sha256": source_hash,
        "restored_database": final_info,
        "pre_restore_backup": str(pre_restore) if pre_restore else None,
        "pre_restore_database": pre_restore_info,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate and atomically restore the AI Agents SQLite database")
    parser.add_argument("--source-path", help="Existing backup inside /data/backups; stdin is used when omitted")
    parser.add_argument("--skip-pre-restore-backup", action="store_true",
                        help="Use only when a verified external rollback backup already exists")
    args = parser.parse_args()
    candidate: Path | None = None
    try:
        if args.source_path:
            candidate = Path(args.source_path).resolve()
            if BACKUP_DIR.resolve() not in candidate.parents:
                raise RuntimeError("--source-path must be a file inside /data/backups")
        else:
            candidate = DATA_DIR / f".restore-input-{timestamp()}.db"
            read_stdin_backup(candidate)
        result = restore(candidate, skip_pre_restore_backup=args.skip_pre_restore_backup)
        if not args.source_path and candidate.exists():
            retained = BACKUP_DIR / f"restore-source-{timestamp()}.db"
            os.replace(candidate, retained)
            os.chmod(retained, 0o600)
            result["restore_source_copy"] = str(retained)
        print(json.dumps(result, separators=(",", ":")))
        return 0
    except Exception as exc:
        print(json.dumps({"status": "error", "error": str(exc)}), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
