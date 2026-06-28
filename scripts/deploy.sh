#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  echo "Uso: $0"
  echo "El ambiente activo sale de entorno/.env (ENTORNO_MODE=qa|production)."
  exit 0
fi

if [[ "$#" -ne 0 ]]; then
  echo "Uso: $0" >&2
  echo "El ambiente activo sale de entorno/.env (ENTORNO_MODE=qa|production)." >&2
  exit 1
fi
"${SCRIPT_DIR}/deploy-common.sh"
