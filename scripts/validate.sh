#!/usr/bin/env bash
# Offline/static validation. Docker integration tests are a separate explicit phase.
set -o pipefail
main() {
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || return 1
printf '\n===== SHELL SYNTAX =====\n'
for script in build-fedora-ai-agents-explainer.sh install-fedora-ai-agents.sh uninstall-fedora-ai-agents.sh scripts/*.sh; do
    bash -n "$script" || return 1
    printf 'PASS %s\n' "$script"
done
printf '\n===== PYTHON BYTECODE VALIDATION =====\n'
python3 -m compileall -q backend || return 1
printf 'PASS Python compilation\n'
if [ -x .venv/bin/python ]; then
    PYTHONPATH=backend .venv/bin/python -m pytest -q backend/tests || return 1
else
    printf 'Python test dependencies are not installed; run the root build script first.\n'
fi
printf '\n===== FRONTEND PRODUCTION BUILD =====\n'
npm run build || return 1
printf '\n===== COMPOSE CONFIGURATION =====\n'
docker compose config --quiet || return 1
printf 'PASS Docker Compose configuration\n'
printf '\nValidation completed. Runtime integration tests require Docker.\n'
    return 0
}
main "$@"
