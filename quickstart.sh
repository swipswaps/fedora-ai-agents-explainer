#!/usr/bin/env bash
# Copyable quick-start commands for an already cloned repository.
set -o pipefail
main() {
cd "$(dirname -- "${BASH_SOURCE[0]}")" || return 1
docker compose up --build -d || return 1
npm install --no-audit --no-fund || return 1
npm run dev
    return 0
}
main "$@"
