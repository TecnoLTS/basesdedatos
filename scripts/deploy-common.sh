#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ENV_MODE="${SCRIPT_DIR}/../../scripts/env-mode.sh"
# shellcheck disable=SC1090
source "${WORKSPACE_ENV_MODE}"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

mode="$(env_mode_from_file "${SCRIPT_DIR}/../entorno/.env")"
deploy_database "${mode}"
