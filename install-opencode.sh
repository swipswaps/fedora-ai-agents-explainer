#!/usr/bin/env bash
# Official OpenCode V2 CLI installer command, with post-install verification.
# Review https://opencode.ai/docs/ before execution; this invokes the official upstream installer.
set -o pipefail
main() {
export PATH="$HOME/.local/bin:$HOME/.opencode/bin:$HOME/.local/share/npm/bin:$PATH"

if command -v opencode >/tmp/fedora-ai-agents-command-check.log 2>&1; then
    printf 'OpenCode is already installed: '
    opencode --version
    printf 'No reinstall was performed.\n'
    return 0
fi

printf 'Downloading the official OpenCode installer from https://opencode.ai/v2/install\n'
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/fedora-ai-agents"
mkdir -p "$CACHE_DIR" || return 1
INSTALLER_FILE="$CACHE_DIR/opencode-v2-install.sh"
INSTALLER_TEMP="$(mktemp "$CACHE_DIR/.opencode-installer.XXXXXX")" || return 1
if ! curl --fail --location --silent --show-error \
    --output "$INSTALLER_TEMP" https://opencode.ai/v2/install; then
    printf 'OpenCode installer download failed; preserving the partial response for inspection.\n' >&2
    mv -f "$INSTALLER_TEMP" "$CACHE_DIR/opencode-installer-download-failed.$(date -u +%Y%m%dT%H%M%SZ)"
    return 1
fi
if ! bash -n "$INSTALLER_TEMP"; then
    printf 'Downloaded OpenCode installer failed bash syntax validation; preserving it for inspection.\n' >&2
    mv -f "$INSTALLER_TEMP" "$CACHE_DIR/opencode-installer-syntax-failed.$(date -u +%Y%m%dT%H%M%SZ)"
    return 1
fi
printf 'Downloaded installer SHA-256: '
sha256sum "$INSTALLER_TEMP" || return 1
if [ -f "$INSTALLER_FILE" ] && ! cmp -s "$INSTALLER_TEMP" "$INSTALLER_FILE"; then
    cp -a "$INSTALLER_FILE" "$INSTALLER_FILE.backup.$(date -u +%Y%m%dT%H%M%SZ)" || return 1
fi
mv -f "$INSTALLER_TEMP" "$INSTALLER_FILE" || return 1
printf 'Executing the downloaded, syntax-checked installer: %s\n' "$INSTALLER_FILE"
bash "$INSTALLER_FILE" || return 1

if ! command -v opencode >/tmp/fedora-ai-agents-command-check.log 2>&1; then
    printf 'Installer returned but opencode is not on PATH. Review the installer output and PATH.\n' >&2
    return 1
fi
opencode --version || return 1
printf '\nReview configured providers with:\n  opencode auth list\nThen authenticate a selected provider, for example:\n  opencode auth login anthropic\n'
    return 0
}
main "$@"
