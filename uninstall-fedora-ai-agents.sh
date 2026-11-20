#!/usr/bin/env bash
# Safe user-level removal. Docker volume and database are preserved by default.
set -o pipefail
main() {
REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/fedora-ai-agents-web.service"
COLLECTOR_SERVICE_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/fedora-ai-agents-collector.service"
COLLECTOR_TIMER_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/fedora-ai-agents-collector.timer"
DESKTOP_FILE="${XDG_DATA_HOME:-$HOME/.local/share}/applications/fedora-ai-agents.desktop"
AGENT_DESKTOP_FILE="${XDG_DATA_HOME:-$HOME/.local/share}/applications/fedora-ai-agent-launcher.desktop"
printf '\n===== SAFE UNINSTALL =====\n'
systemctl --user disable --now fedora-ai-agents-collector.timer
systemctl --user disable --now fedora-ai-agents-collector.service
systemctl --user disable --now fedora-ai-agents-web.service
STATUS=$?
if [ "$STATUS" -ne 0 ]; then
    printf 'The user service was not active or could not be stopped (status %s). Continuing with file audit.\n' "$STATUS"
fi
for unit_file in "$COLLECTOR_SERVICE_FILE" "$COLLECTOR_TIMER_FILE"; do
    if [ -f "$unit_file" ]; then
        cp -a "$unit_file" "${unit_file}.backup.$(date -u +%Y%m%dT%H%M%SZ)"
        rm -f -- "$unit_file"
    fi
done
if [ -f "$SERVICE_FILE" ]; then
    cp -a "$SERVICE_FILE" "${SERVICE_FILE}.backup.$(date -u +%Y%m%dT%H%M%SZ)"
    rm -f -- "$SERVICE_FILE"
fi
if [ -f "$DESKTOP_FILE" ]; then
    cp -a "$DESKTOP_FILE" "${DESKTOP_FILE}.backup.$(date -u +%Y%m%dT%H%M%SZ)"
    rm -f -- "$DESKTOP_FILE"
fi
if [ -f "$AGENT_DESKTOP_FILE" ]; then
    cp -a "$AGENT_DESKTOP_FILE" "${AGENT_DESKTOP_FILE}.backup.$(date -u +%Y%m%dT%H%M%SZ)"
    rm -f -- "$AGENT_DESKTOP_FILE"
fi
systemctl --user daemon-reload
if command -v docker >/tmp/fedora-ai-agents-command-check.log 2>&1; then
    docker compose -f "$REPO_DIR/docker-compose.yml" down
fi
printf '\nApplication launcher removed. Docker data volume is intentionally preserved.\n'
printf 'To remove the application data permanently, first export/verify a backup, then explicitly run:\n'
printf '  docker volume rm fedora-ai-agents-data\n'
printf 'That destructive data-removal command is not executed by this uninstaller.\n'
    return 0
}
main "$@"
