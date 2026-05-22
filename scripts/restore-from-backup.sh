#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

MODE="${1:-production}"
ENV_FILE="$(resolve_env_file "${MODE}")"

ensure_prereqs
load_env_file "${ENV_FILE}"

if [[ ! -f "${BACKUP_FILE}" ]]; then
  echo "No existe el snapshot ${BACKUP_FILE}. Ejecuta primero ./scripts/backup-and-stop.sh ${MODE}" >&2
  exit 1
fi

RESTORE_ROLE="codex_restore_$(date +%s)"
RESTORE_DB="${RESTORE_ROLE}_db"
RESTORE_PASSWORD="$(openssl rand -hex 32)"

cleanup_restore_artifacts() {
  compose_cmd "${ENV_FILE}" exec -T -e PGPASSWORD="${POSTGRES_PASSWORD}" db \
    psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER}" -d postgres -c "DROP DATABASE IF EXISTS ${RESTORE_DB};" >/dev/null 2>&1 || true
  compose_cmd "${ENV_FILE}" exec -T -e PGPASSWORD="${POSTGRES_PASSWORD}" db \
    psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER}" -d postgres -c "DROP ROLE IF EXISTS ${RESTORE_ROLE};" >/dev/null 2>&1 || true
}

trap cleanup_restore_artifacts EXIT

echo "Recreando servicio PostgreSQL desde ${BACKUP_FILE}..."
compose_cmd "${ENV_FILE}" down --remove-orphans
reset_data_dir
compose_cmd "${ENV_FILE}" up -d --remove-orphans db
wait_for_db "${ENV_FILE}"

echo "Creando rol temporal de restauracion..."
compose_cmd "${ENV_FILE}" exec -T -e PGPASSWORD="${POSTGRES_PASSWORD}" db \
  psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER}" -d postgres -c "CREATE ROLE ${RESTORE_ROLE} WITH LOGIN SUPERUSER PASSWORD '${RESTORE_PASSWORD}';"
compose_cmd "${ENV_FILE}" exec -T -e PGPASSWORD="${POSTGRES_PASSWORD}" db \
  psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER}" -d postgres -c "CREATE DATABASE ${RESTORE_DB} OWNER ${RESTORE_ROLE};"

echo "Restaurando cluster completo desde backup cifrado..."
decrypt_backup_stream < "${BACKUP_FILE}" \
  | normalize_dump_stream \
  | compose_cmd "${ENV_FILE}" exec -T -e PGPASSWORD="${RESTORE_PASSWORD}" db psql -v ON_ERROR_STOP=1 -U "${RESTORE_ROLE}" -d "${RESTORE_DB}"

echo "Eliminando rol temporal de restauracion..."
cleanup_restore_artifacts
trap - EXIT

echo "Verificando estado del servicio..."
compose_cmd "${ENV_FILE}" exec -T db pg_isready -U "${POSTGRES_USER}" -d postgres >/dev/null
compose_cmd "${ENV_FILE}" ps

echo "Base de datos restaurada desde backup"
