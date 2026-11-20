#!/usr/bin/env bash
# Minimal Xfce-friendly launcher. It starts only installed commands from this fixed allowlist.
# It never evaluates arbitrary input as shell code and never handles provider credentials.
set -o pipefail
main() {

AGENT_NAMES=("OpenCode" "Claude Code" "OpenAI Codex" "Gemini CLI" "Pi" "GitHub Copilot CLI")
AGENT_COMMANDS=("opencode" "claude" "codex" "gemini" "pi" "copilot")
AVAILABLE_NAMES=()
AVAILABLE_COMMANDS=()

for index in "${!AGENT_COMMANDS[@]}"; do
    if command -v "${AGENT_COMMANDS[$index]}" >/tmp/fedora-ai-agents-command-check.log 2>&1; then
        AVAILABLE_NAMES+=("${AGENT_NAMES[$index]}")
        AVAILABLE_COMMANDS+=("${AGENT_COMMANDS[$index]}")
    fi
done

if [ "${#AVAILABLE_COMMANDS[@]}" -eq 0 ]; then
    printf 'No supported coding-agent executables were detected.\n' >&2
    printf 'Install OpenCode from the repository root with: bash ./install-opencode.sh\n' >&2
    return 1
fi

SELECTED=""
if command -v zenity >/tmp/fedora-ai-agents-command-check.log 2>&1; then
    ZENITY_ARGS=(--list --radiolist --title="AI Coding Agents" --text="Choose an installed coding agent" --column="Select" --column="Agent" --column="Command" --height=340 --width=520)
    for index in "${!AVAILABLE_COMMANDS[@]}"; do
        if [ "$index" -eq 0 ]; then PICK=TRUE; else PICK=FALSE; fi
        ZENITY_ARGS+=("$PICK" "${AVAILABLE_NAMES[$index]}" "${AVAILABLE_COMMANDS[$index]}")
    done
    SELECTED="$(zenity "${ZENITY_ARGS[@]}")"
    if [ -z "$SELECTED" ]; then return 0; fi
else
    printf '\nInstalled coding agents:\n'
    select SELECTED in "${AVAILABLE_COMMANDS[@]}" "Cancel"; do
        if [ "$SELECTED" = "Cancel" ] || [ -z "$SELECTED" ]; then return 0; fi
        break
    done
fi

if ! printf '%s\n' "${AVAILABLE_COMMANDS[@]}" | awk -v selected="$SELECTED" '$0 == selected { found=1 } END { exit(found ? 0 : 1) }'; then
    printf 'Selection is not in the detected executable allowlist.\n' >&2
    return 1
fi

if command -v xfce4-terminal >/tmp/fedora-ai-agents-command-check.log 2>&1; then
    xfce4-terminal --disable-server --command="$SELECTED"
else
    printf 'xfce4-terminal was not found. Starting %s in the current terminal.\n' "$SELECTED"
    exec "$SELECTED"
fi
    return 0
}
main "$@"
