#!/usr/bin/env bash
# Runs as the logged-in Fedora user. The Docker API never mounts the OpenCode DB.
# OpenCode's official database path command is documented at:
# https://opencode.ai/docs/cli/commands
set -o pipefail
main() {
REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
API_URL="${FEDORA_AI_AGENTS_INGEST_URL:-http://127.0.0.1:8000/api/ingest/host-snapshot}"
TEMP_FILE="$(mktemp "${TMPDIR:-/tmp}/fedora-ai-agents-snapshot.XXXXXX")" || return 1
export PATH="$HOME/.local/bin:$HOME/.opencode/bin:$PATH"
if command -v opencode >/tmp/fedora-ai-agents-command-check.log 2>&1; then
    if OPENCODE_DATABASE="$(opencode debug paths db)"; then
        if [ -f "$OPENCODE_DATABASE" ]; then
            export OPENCODE_DB_PATH="$OPENCODE_DATABASE"
            printf 'OpenCode database resolved by the official CLI path command.\n'
        else
            printf 'OpenCode executable exists, but the resolved database file is absent; using the XDG default for explicit status reporting.\n'
            export OPENCODE_DB_PATH="${OPENCODE_DB_PATH:-${XDG_DATA_HOME:-$HOME/.local/share}/opencode/opencode.db}"
        fi
    else
        printf 'OpenCode debug paths db failed; collector will report database-unavailable unless the XDG default exists.\n' >&2
        export OPENCODE_DB_PATH="${OPENCODE_DB_PATH:-${XDG_DATA_HOME:-$HOME/.local/share}/opencode/opencode.db}"
    fi
fi
printf '\n===== COLLECT HOST AGENTS AND USAGE METADATA =====\n'
PYTHONPATH="$REPO_DIR/backend${PYTHONPATH:+:$PYTHONPATH}" python3 -m collectors.host_snapshot > "$TEMP_FILE" || {
    rm -f -- "$TEMP_FILE"
    return 1
}
printf '\n===== INGEST SANITIZED SNAPSHOT OVER LOOPBACK =====\n'
curl --fail --silent --show-error --connect-timeout 5 --max-time 120 --retry 3 --retry-connrefused --retry-delay 2 \
    -H 'Content-Type: application/json' \
    --data-binary "@$TEMP_FILE" "$API_URL"
CURL_STATUS=$?
rm -f -- "$TEMP_FILE"
if [ "$CURL_STATUS" -ne 0 ]; then
    printf 'Host snapshot was not accepted. Verify the local API: %s\n' "$API_URL" >&2
    return "$CURL_STATUS"
fi
printf '\nHost snapshot submitted successfully. No credentials or message bodies were sent.\n'
return 0
}
main "$@"
