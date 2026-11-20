#!/usr/bin/env bash
# User-scoped Fedora 43 Xfce/X11 installer. It does not replace OpenCode configuration,
# edit OpenCode credentials, alter source databases, or remove Docker volumes.
set -o pipefail
main() {

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$SCRIPT_DIR"
USER_SERVICE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
DESKTOP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
SERVICE_FILE="$USER_SERVICE_DIR/fedora-ai-agents-web.service"
COLLECTOR_SERVICE_FILE="$USER_SERVICE_DIR/fedora-ai-agents-collector.service"
COLLECTOR_TIMER_FILE="$USER_SERVICE_DIR/fedora-ai-agents-collector.timer"
DESKTOP_FILE="$DESKTOP_DIR/fedora-ai-agents.desktop"
AGENT_DESKTOP_FILE="$DESKTOP_DIR/fedora-ai-agent-launcher.desktop"

printf '\n===== FEDORA AI AGENTS INSTALLER =====\n'
printf 'Repository: %s\n' "$REPO_DIR"
printf 'User: %s\n' "${USER:-unknown}"

for command_name in node npm python3 git docker curl; do
    if ! command -v "$command_name" >/tmp/fedora-ai-agents-command-check.log; then
        printf 'MISSING: %s\n' "$command_name" >&2
        printf 'Install the missing prerequisite, then rerun this script.\n' >&2
        return 1
    fi
done
if ! docker compose version >/tmp/fedora-ai-agents-command-check.log 2>&1; then
    printf 'Docker Compose v2 plugin is required.\n' >&2
    return 1
fi
if ! docker info >/tmp/fedora-ai-agents-command-check.log 2>&1; then
    printf 'Docker daemon is not reachable. Start/enable Docker before continuing.\n' >&2
    printf 'Typical Fedora command: sudo systemctl enable --now docker\n' >&2
    return 1
fi
NODE_VERSION="$(node -p 'process.versions.node')"
if ! node -e 'const [major,minor] = process.versions.node.split(".").map(Number); const ok = major > 22 || (major === 22 && minor >= 12) || (major === 20 && minor >= 19); if (!ok) process.exitCode = 1;'; then
    printf 'Vite 7 requires Node.js 20.19+, 22.12+, or newer; detected %s\n' "$NODE_VERSION" >&2
    return 1
fi

printf '\n===== VALIDATE PROJECT FILES =====\n'
for required in package.json vite.config.js docker-compose.yml backend/main.py backend/restore_db.py backend/Dockerfile backend/collectors agent-launcher.sh install-opencode.sh scripts/backup_db.sh scripts/restore_db.sh; do
    if [ ! -f "$REPO_DIR/$required" ]; then
        printf 'Missing project file: %s\n' "$required" >&2
        return 1
    fi
done

printf '\n===== INSTALL FRONTEND DEPENDENCIES =====\n'
cd "$REPO_DIR" || return 1
if [ -s package-lock.json ]; then
    npm ci
    NPM_STATUS=$?
else
    printf 'No package-lock.json exists yet; performing the first install and generating it.\n'
    npm install --no-audit --no-fund
    NPM_STATUS=$?
fi
if [ "$NPM_STATUS" -ne 0 ]; then
    printf 'npm install failed; no system files were changed.\n' >&2
    return "$NPM_STATUS"
fi

printf '\n===== BUILD LOCAL BACKEND =====\n'
docker compose config --quiet || return 1
docker compose up --build -d || return 1

printf '\n===== CREATE USER-LEVEL WEB SERVICE =====\n'
mkdir -p "$USER_SERVICE_DIR" "$DESKTOP_DIR"
NODE_BIN="$(command -v node)"
NPM_BIN="$(command -v npm)"
NODE_BIN_DIR="$(dirname "$NODE_BIN")"
SERVICE_TEMP="$(mktemp "${USER_SERVICE_DIR}/.fedora-ai-agents.XXXXXX")"
cat > "$SERVICE_TEMP" <<SERVICE_EOF
[Unit]
Description=Fedora AI Agents local Vite dashboard
After=network.target

[Service]
Type=simple
# systemd does not source interactive shell startup files. Use absolute Node/npm
# paths and explicitly preserve the Node bin directory for npm's child scripts.
# Environment and ExecStart semantics: https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html
WorkingDirectory="$REPO_DIR"
ExecStart="$NPM_BIN" run dev -- --host 127.0.0.1
Restart=on-failure
RestartSec=4
Environment=NODE_ENV=development
Environment="PATH=$NODE_BIN_DIR:$PATH"

[Install]
WantedBy=default.target
SERVICE_EOF
if [ -f "$SERVICE_FILE" ] && ! cmp -s "$SERVICE_TEMP" "$SERVICE_FILE"; then
    cp -a "$SERVICE_FILE" "${SERVICE_FILE}.backup.$(date -u +%Y%m%dT%H%M%SZ)"
fi
mv -f "$SERVICE_TEMP" "$SERVICE_FILE"

DESKTOP_TEMP="$(mktemp "${DESKTOP_DIR}/.fedora-ai-agents.XXXXXX")"
cat > "$DESKTOP_TEMP" <<DESKTOP_EOF
[Desktop Entry]
Type=Application
Name=Fedora AI Agents
Comment=Local AI coding agent dashboard
Exec=xdg-open http://127.0.0.1:5173/
Icon=applications-development
Terminal=false
Categories=Development;Utility;
StartupNotify=true
DESKTOP_EOF
if [ -f "$DESKTOP_FILE" ] && ! cmp -s "$DESKTOP_TEMP" "$DESKTOP_FILE"; then
    cp -a "$DESKTOP_FILE" "${DESKTOP_FILE}.backup.$(date -u +%Y%m%dT%H%M%SZ)"
fi
mv -f "$DESKTOP_TEMP" "$DESKTOP_FILE"
AGENT_DESKTOP_TEMP="$(mktemp "${DESKTOP_DIR}/.fedora-ai-agent-launcher.XXXXXX")"
cat > "$AGENT_DESKTOP_TEMP" <<AGENT_DESKTOP_EOF
[Desktop Entry]
Type=Application
Name=AI Coding Agents
Comment=Launch an installed AI coding agent
Exec=$REPO_DIR/agent-launcher.sh
Icon=utilities-terminal
Terminal=true
Categories=Development;Utility;
StartupNotify=true
AGENT_DESKTOP_EOF
if [ -f "$AGENT_DESKTOP_FILE" ] && ! cmp -s "$AGENT_DESKTOP_TEMP" "$AGENT_DESKTOP_FILE"; then
    cp -a "$AGENT_DESKTOP_FILE" "${AGENT_DESKTOP_FILE}.backup.$(date -u +%Y%m%dT%H%M%SZ)"
fi
mv -f "$AGENT_DESKTOP_TEMP" "$AGENT_DESKTOP_FILE"
COLLECTOR_SERVICE_TEMP="$(mktemp "${USER_SERVICE_DIR}/.fedora-ai-agents-collector.XXXXXX")"
cat > "$COLLECTOR_SERVICE_TEMP" <<COLLECTOR_SERVICE_EOF
[Unit]
Description=Fedora AI Agents host-side usage and executable snapshot
After=network.target

[Service]
Type=oneshot
TimeoutStartSec=180
WorkingDirectory=$REPO_DIR
Environment="PATH=$PATH:$HOME/.local/bin:$HOME/.opencode/bin:/usr/local/bin:/usr/bin:/bin"
Environment=PYTHONPATH=$REPO_DIR/backend
ExecStart=$REPO_DIR/scripts/refresh_host_snapshot.sh
COLLECTOR_SERVICE_EOF
if [ -f "$COLLECTOR_SERVICE_FILE" ] && ! cmp -s "$COLLECTOR_SERVICE_TEMP" "$COLLECTOR_SERVICE_FILE"; then
    cp -a "$COLLECTOR_SERVICE_FILE" "${COLLECTOR_SERVICE_FILE}.backup.$(date -u +%Y%m%dT%H%M%SZ)"
fi
mv -f "$COLLECTOR_SERVICE_TEMP" "$COLLECTOR_SERVICE_FILE"
COLLECTOR_TIMER_TEMP="$(mktemp "${USER_SERVICE_DIR}/.fedora-ai-agents-collector-timer.XXXXXX")"
cat > "$COLLECTOR_TIMER_TEMP" <<'COLLECTOR_TIMER_EOF'
[Unit]
Description=Periodic Fedora AI Agents host snapshot

[Timer]
OnBootSec=2min
OnUnitActiveSec=15min
Persistent=true
AccuracySec=1min
Unit=fedora-ai-agents-collector.service

[Install]
WantedBy=timers.target
COLLECTOR_TIMER_EOF
if [ -f "$COLLECTOR_TIMER_FILE" ] && ! cmp -s "$COLLECTOR_TIMER_TEMP" "$COLLECTOR_TIMER_FILE"; then
    cp -a "$COLLECTOR_TIMER_FILE" "${COLLECTOR_TIMER_FILE}.backup.$(date -u +%Y%m%dT%H%M%SZ)"
fi
mv -f "$COLLECTOR_TIMER_TEMP" "$COLLECTOR_TIMER_FILE"
chmod 0644 "$DESKTOP_FILE" "$AGENT_DESKTOP_FILE" "$SERVICE_FILE" "$COLLECTOR_SERVICE_FILE" "$COLLECTOR_TIMER_FILE"

systemctl --user daemon-reload || return 1
systemctl --user enable --now fedora-ai-agents-web.service || return 1
systemctl --user enable --now fedora-ai-agents-collector.timer || return 1
systemctl --user start fedora-ai-agents-collector.service || return 1

printf '\n===== VERIFY LOCAL SERVICES =====\n'
API_READY=0
for attempt in $(seq 1 30); do
    if curl --fail --silent --show-error http://127.0.0.1:8000/health; then
        printf '\nAPI health check passed.\n'
        API_READY=1
        break
    fi
    sleep 2
done
if [ "$API_READY" -ne 1 ]; then
    printf 'API health check did not pass after 60 seconds. Inspect: docker compose logs api\n' >&2
    return 1
fi
curl --fail --silent --show-error http://127.0.0.1:8000/api/capabilities | python3 -m json.tool || return 1

printf '\n===== VERIFY LOCAL FRONTEND BEFORE OPENING IT =====\n'
# The desktop launcher must not open a URL just because systemd accepted the
# service. Verify Vite returned the actual app shell before invoking xdg-open.
# xdg-open is supplied by xdg-utils: https://gitlab.freedesktop.org/xdg/xdg-utils
FRONTEND_URL="http://127.0.0.1:5173/"
FRONTEND_HTML="$(mktemp /tmp/fedora-ai-agents-local-page.XXXXXX.html)" || return 1
FRONTEND_READY=0
for attempt in $(seq 1 30); do
    FRONTEND_STATUS="$(curl --location --silent --show-error --connect-timeout 2 --max-time 5 \
        --output "$FRONTEND_HTML" --write-out '%{http_code}' "$FRONTEND_URL")"
    if [ "$FRONTEND_STATUS" = "200" ] && awk 'index($0, "Fedora AI Agents") { found=1 } END { exit(found ? 0 : 1) }' "$FRONTEND_HTML"; then
        printf 'Local frontend verification %s/30: HTTP 200 and expected app identity.\n' "$attempt"
        FRONTEND_READY=1
        break
    fi
    printf 'Local frontend verification %s/30: HTTP %s; waiting for Vite.\n' "$attempt" "${FRONTEND_STATUS:-no-response}"
    sleep 2
done
rm -f -- "$FRONTEND_HTML"
if [ "$FRONTEND_READY" -ne 1 ]; then
    printf 'Local frontend did not become ready. Inspect: systemctl --user status fedora-ai-agents-web.service\n' >&2
    journalctl --user -u fedora-ai-agents-web.service -n 80 --no-pager >&2
    return 1
fi

printf '\nInstalled desktop entry: %s\n' "$DESKTOP_FILE"
printf 'Verified local URL: %s\n' "$FRONTEND_URL"
if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
    printf 'No graphical session detected; open manually: %s\n' "$FRONTEND_URL"
else
    XDG_OPEN_LOG="$(mktemp /tmp/fedora-ai-agents-local-xdg.XXXXXX.log)" || return 1
    if xdg-open "$FRONTEND_URL" > "$XDG_OPEN_LOG" 2>&1; then
        printf 'xdg-open accepted the verified local URL.\n'
        if [ -s "$XDG_OPEN_LOG" ]; then cat "$XDG_OPEN_LOG"; fi
    else
        XDG_STATUS=$?
        printf 'xdg-open failed (exit %s). Output follows.\n' "$XDG_STATUS" >&2
        cat "$XDG_OPEN_LOG" >&2
        rm -f -- "$XDG_OPEN_LOG"
        return 1
    fi
    rm -f -- "$XDG_OPEN_LOG"
fi
printf '\nInstallation completed. Existing OpenCode config and source DB were not modified.\n'
    return 0
}
main "$@"
