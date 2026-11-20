#!/usr/bin/env bash
# Restore a verified SQLite backup while the API is stopped; preserve and verify rollback state.
# SQLite WAL and online backup references: https://www.sqlite.org/wal.html and
# https://www.sqlite.org/backup.html
set -o pipefail
wait_for_api() {
    local attempt
    for attempt in $(seq 1 30); do
        if curl --fail --silent --show-error --connect-timeout 3 --max-time 5 http://127.0.0.1:8000/health; then
            printf '\nAPI health check passed.\n'
            return 0
        fi
        sleep 2
    done
    return 1
}
main() {
umask 077
PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR" || return 1
BACKUP_PATH="${1:-}"
if [ -z "$BACKUP_PATH" ] || [ ! -s "$BACKUP_PATH" ]; then
    printf 'Usage: %s /absolute/path/to/verified-agents-backup.db\n' "$0" >&2
    return 2
fi
BACKUP_PATH="$(cd -- "$(dirname -- "$BACKUP_PATH")" && pwd)/$(basename -- "$BACKUP_PATH")"
if ! command -v docker >/tmp/fedora-ai-agents-command-check.log 2>&1; then
    printf 'Docker CLI is required for restore.\n' >&2
    return 1
fi
docker compose config --quiet || return 1
CONTAINER_ID="$(docker compose ps -q api)"
if [ -z "$CONTAINER_ID" ]; then
    printf 'The API container must be running so a verified pre-restore backup can be created.\n' >&2
    return 1
fi
PRE_RESTORE_DIR="$PROJECT_DIR/backups/pre-restore"
mkdir -p -m 0700 "$PRE_RESTORE_DIR" || return 1
chmod 0700 "$PRE_RESTORE_DIR" || return 1
printf '\n===== CREATE VERIFIED PRE-RESTORE BACKUP =====\n'
BACKUP_OUTPUT="$(bash "$PROJECT_DIR/scripts/backup_db.sh" "$PRE_RESTORE_DIR")" || return 1
printf '%s\n' "$BACKUP_OUTPUT"
PRE_HOST_PATH="$(printf '%s\n' "$BACKUP_OUTPUT" | awk -F': ' '/^Path: / {path=$2} END {print path}')"
if [ -z "$PRE_HOST_PATH" ] || [ ! -s "$PRE_HOST_PATH" ]; then
    printf 'Could not resolve the verified pre-restore backup path. Restore cancelled.\n' >&2
    return 1
fi
printf '\n===== STOP API AND VALIDATE/RESTORE BACKUP =====\n'
printf 'Requested backup: %s\n' "$BACKUP_PATH"
printf 'Host rollback backup: %s\n' "$PRE_HOST_PATH"
docker compose stop api || return 1
RESTORE_OUTPUT="$(cat "$BACKUP_PATH" | docker compose run --rm -T --no-deps api python /app/restore_db.py)"
RESTORE_STATUS=$?
if [ "$RESTORE_STATUS" -ne 0 ]; then
    printf '%s\n' "$RESTORE_OUTPUT" >&2
    printf 'Restore validation failed before commit or automatic rollback completed. Restarting the original API container.\n' >&2
    docker compose start api
    return "$RESTORE_STATUS"
fi
printf '%s\n' "$RESTORE_OUTPUT"
PRE_CONTAINER_PATH="$(printf '%s\n' "$RESTORE_OUTPUT" | awk '/^\{/ {json=$0} END {print json}' | python3 -c 'import json,sys; print(json.load(sys.stdin).get("pre_restore_backup") or "")')"
if [ -z "$PRE_CONTAINER_PATH" ]; then
    printf 'Restore helper did not return its internal rollback path. Starting API; host rollback backup remains available at %s.\n' "$PRE_HOST_PATH" >&2
    docker compose start api
    return 1
fi
printf '\n===== START AND VERIFY RESTORED API =====\n'
docker compose start api || return 1
if wait_for_api; then
    printf 'Restore completed. Pre-restore rollback copy: %s\nHost rollback copy: %s\n' "$PRE_CONTAINER_PATH" "$PRE_HOST_PATH"
    return 0
fi
printf 'Restored database did not pass API health. Attempting automatic rollback from the pre-restore database.\n' >&2
docker compose stop api || return 1
docker compose run --rm --no-deps api python /app/restore_db.py --source-path "$PRE_CONTAINER_PATH"
ROLLBACK_STATUS=$?
if [ "$ROLLBACK_STATUS" -ne 0 ]; then
    printf 'Internal rollback failed; restoring the verified host backup without taking another backup of the failed database.\n' >&2
    cat "$PRE_HOST_PATH" | docker compose run --rm -T --no-deps api python /app/restore_db.py --skip-pre-restore-backup
    ROLLBACK_STATUS=$?
fi
docker compose start api || return 1
if [ "$ROLLBACK_STATUS" -ne 0 ]; then
    printf 'Automatic rollback failed. Verified host rollback backup remains at: %s\n' "$PRE_HOST_PATH" >&2
    return "$ROLLBACK_STATUS"
fi
if wait_for_api; then
    printf 'Original database restored successfully after failed restore health check. Host backup: %s\n' "$PRE_HOST_PATH" >&2
else
    printf 'Rollback file restored, but API health still fails. Inspect docker compose logs api. Host backup: %s\n' "$PRE_HOST_PATH" >&2
fi
return 1
}
main "$@"
