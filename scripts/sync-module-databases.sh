#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

if [[ "$#" -ne 0 ]]; then
  echo "Uso: $0" >&2
  echo "El ambiente activo sale de entorno/.env (ENTORNO_MODE=qa|production)." >&2
  exit 1
fi

MODE="$(env_mode_from_file "${SCRIPT_DIR}/../entorno/.env")"
require_valid_mode "${MODE}"

ensure_prereqs
ENV_FILE="$(resolve_env_file "${MODE}")"
load_env_file "${ENV_FILE}"

echo "Sincronizando bases por modulo en ${MODE}..."
compose_cmd "${ENV_FILE}" up -d db >/dev/null
wait_for_db "${ENV_FILE}"
assert_db_mode "${ENV_FILE}"
sync_module_databases "${ENV_FILE}"
echo "Bases por modulo sincronizadas."
