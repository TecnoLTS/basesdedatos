#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

MODE="${1:-$(default_mode)}"
require_valid_mode "${MODE}"

ensure_prereqs
ENV_FILE="$(resolve_env_file "${MODE}")"
load_env_file "${ENV_FILE}"

echo "Sincronizando bases por modulo en ${MODE}..."
compose_cmd "${ENV_FILE}" up -d db >/dev/null
wait_for_db "${ENV_FILE}"
assert_db_mode "${MODE}"
sync_module_databases "${ENV_FILE}"
echo "Bases por modulo sincronizadas."
