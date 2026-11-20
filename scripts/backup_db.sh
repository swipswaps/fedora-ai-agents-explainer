#!/usr/bin/env bash
# Use SQLite's online backup API; copying agents.db alone can omit committed WAL pages.
# SQLite WAL and backup API references: https://www.sqlite.org/wal.html and
# https://www.sqlite.org/backup.html
set -o pipefail
main() {
umask 077
PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR" || return 1
BACKUP_DIR="${1:-${PROJECT_DIR}/backups}"
mkdir -p -m 0700 "$BACKUP_DIR" || return 1
chmod 0700 "$BACKUP_DIR" || return 1
BACKUP_NAME="agents-$(date -u '+%Y%m%dT%H%M%S%NZ').db"
BACKUP_PATH="$BACKUP_DIR/$BACKUP_NAME"
CONTAINER_ID="$(docker compose ps -q api)"
if [ -z "$CONTAINER_ID" ]; then
    printf 'API container is not running; start it before backup.\n' >&2
    return 1
fi
docker compose exec -T api python - "$BACKUP_NAME" <<'PY'
import sqlite3, sqlite_vec, sys
name = sys.argv[1]
source = sqlite3.connect('/data/agents.db', timeout=8)
target = sqlite3.connect('/tmp/' + name)
try:
    for connection in (source, target):
        connection.enable_load_extension(True)
        try:
            sqlite_vec.load(connection)
        finally:
            connection.enable_load_extension(False)
    source.backup(target)
    result = target.execute('PRAGMA integrity_check').fetchone()[0]
    if result != 'ok':
        raise SystemExit(f'Backup integrity failure: {result}')
    target.execute('SELECT count(*) FROM documents_fts').fetchone()
    target.execute('SELECT count(*) FROM documents_vec').fetchone()
    print(f'Container backup verified with FTS5 and sqlite-vec: {name}')
finally:
    target.close()
    source.close()
PY
if [ "$?" -ne 0 ]; then return 1; fi
docker cp "${CONTAINER_ID}:/tmp/${BACKUP_NAME}" "$BACKUP_PATH" || return 1
chmod 0600 "$BACKUP_PATH" || return 1
if [ ! -s "$BACKUP_PATH" ]; then
    printf 'Backup copy is missing or empty: %s\n' "$BACKUP_PATH" >&2
    return 1
fi
BACKUP_HASH="$(sha256sum "$BACKUP_PATH" | awk '{print $1}')" || return 1
printf 'Backup copied. SHA-256: %s\nPath: %s\n' "$BACKUP_HASH" "$BACKUP_PATH"
    return 0
}
main "$@"
