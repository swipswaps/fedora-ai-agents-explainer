from __future__ import annotations

import sqlite3
from pathlib import Path

import sqlite_vec

import restore_db


def create_database(path: Path, agent_id: str) -> None:
    connection = sqlite3.connect(path)
    connection.enable_load_extension(True)
    try:
        sqlite_vec.load(connection)
    finally:
        connection.enable_load_extension(False)
    connection.executescript("""
        CREATE TABLE app_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE agents(id TEXT PRIMARY KEY, display_name TEXT NOT NULL);
        CREATE TABLE usage_events(event_id TEXT PRIMARY KEY);
        CREATE TABLE documents(id INTEGER PRIMARY KEY, title TEXT NOT NULL);
        CREATE VIRTUAL TABLE documents_fts USING fts5(title);
        CREATE VIRTUAL TABLE documents_vec USING vec0(embedding float[768]);
        CREATE TABLE schema_migrations(version INTEGER PRIMARY KEY, applied_at TEXT, description TEXT);
    """)
    connection.execute("INSERT INTO agents VALUES (?,?)", (agent_id, agent_id.title()))
    connection.execute("INSERT INTO documents VALUES (1,?)", (agent_id,))
    connection.execute("INSERT INTO documents_fts VALUES (?)", (agent_id,))
    connection.commit()
    connection.close()


def test_restore_uses_online_backup_and_preserves_pre_restore_database(tmp_path, monkeypatch):
    data_dir = tmp_path / "data"
    data_dir.mkdir()
    db_path = data_dir / "agents.db"
    backup_dir = data_dir / "backups"
    source_backup = tmp_path / "source-backup.db"
    monkeypatch.setattr(restore_db, "DATA_DIR", data_dir)
    monkeypatch.setattr(restore_db, "DB_PATH", db_path)
    monkeypatch.setattr(restore_db, "BACKUP_DIR", backup_dir)

    create_database(db_path, "old-agent")
    create_database(source_backup, "new-agent")

    result = restore_db.restore(source_backup)
    assert result["status"] == "restored"
    assert result["restored_database"]["integrity"] == "ok"
    assert result["restored_database"]["fts_rows"] == 1
    assert result["pre_restore_backup"]

    with sqlite3.connect(db_path) as connection:
        assert connection.execute("SELECT id FROM agents").fetchone()[0] == "new-agent"
    with sqlite3.connect(result["pre_restore_backup"]) as connection:
        assert connection.execute("SELECT id FROM agents").fetchone()[0] == "old-agent"

    # A later restore from the saved pre-restore copy acts as a rollback.
    restore_db.restore(Path(result["pre_restore_backup"]))
    with sqlite3.connect(db_path) as connection:
        assert connection.execute("SELECT id FROM agents").fetchone()[0] == "old-agent"


def test_restore_rejects_non_sqlite_input(tmp_path, monkeypatch):
    data_dir = tmp_path / "data"
    data_dir.mkdir()
    monkeypatch.setattr(restore_db, "DATA_DIR", data_dir)
    monkeypatch.setattr(restore_db, "DB_PATH", data_dir / "agents.db")
    monkeypatch.setattr(restore_db, "BACKUP_DIR", data_dir / "backups")
    invalid = tmp_path / "not-a-database.db"
    invalid.write_bytes(b"X" * 128)
    try:
        restore_db.validate_database(invalid)
    except RuntimeError as exc:
        assert "SQLite" in str(exc)
    else:
        raise AssertionError("Non-SQLite backup was accepted")
