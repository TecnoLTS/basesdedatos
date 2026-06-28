#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

umask 077

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  echo "Uso: $0 [qa|production] [ruta-backup.sql.enc]"
  exit 0
fi

MODE="${1:-$(default_mode)}"
require_valid_mode "${MODE}"
MODE="$(canonical_env_mode "${MODE}")"
BACKUP_FILE_ARG="${2:-}"
ENV_FILE="$(resolve_env_file "${MODE}")"

ensure_prereqs
load_env_file "${ENV_FILE}"
BACKUP_PASSPHRASE="${BACKUP_ENCRYPTION_PASSPHRASE_OVERRIDE:-${BACKUP_ENCRYPTION_PASSPHRASE}}"

if [[ -z "${BACKUP_FILE}" ]]; then
  if [[ -n "${BACKUP_FILE_ARG}" ]]; then
    BACKUP_FILE="$(absolute_app_path "${BACKUP_FILE_ARG}")"
  else
    BACKUP_FILE="$(default_backup_file_for_mode "${MODE}")"
  fi
fi

TMP_FILE="${BACKUP_FILE}.tmp"
LATEST_FILE="$(latest_backup_file_for_mode "${MODE}")"
MODE_BACKUP_DIR="$(backup_dir_for_mode "${MODE}")"
mkdir -p "$(dirname "${BACKUP_FILE}")"

running_db_env="$(running_db_env)"
if [[ -n "${running_db_env}" && "${running_db_env}" != "${MODE}" ]]; then
  echo "La base principal esta levantada en modo ${running_db_env}, pero solicitaste backup ${MODE}." >&2
  echo "Usa ./scripts/backup-and-stop.sh ${running_db_env} para respaldar esta base, o despliega ${MODE} antes de respaldar ese ambiente." >&2
  exit 1
fi

echo "Levantando PostgreSQL para exportar el cluster..."
compose_cmd "${ENV_FILE}" up -d --remove-orphans db
wait_for_db "${ENV_FILE}"
assert_db_mode "${MODE}"

echo "Generando snapshot completo cifrado en ${BACKUP_FILE}..."
compose_cmd "${ENV_FILE}" exec -T -e PGPASSWORD="${POSTGRES_PASSWORD}" db \
  pg_dumpall -h 127.0.0.1 -U "${POSTGRES_USER}" --clean --if-exists \
  | normalize_dump_stream | BACKUP_ENCRYPTION_PASSPHRASE="${BACKUP_PASSPHRASE}" encrypt_backup_stream > "${TMP_FILE}"
mv "${TMP_FILE}" "${BACKUP_FILE}"
chmod 600 "${BACKUP_FILE}"
if [[ "$(dirname "${BACKUP_FILE}")" == "${MODE_BACKUP_DIR}" ]]; then
  ln -sfn "$(basename "${BACKUP_FILE}")" "${LATEST_FILE}"
fi
if command -v sha256sum >/dev/null 2>&1; then
  (
    cd "$(dirname "${BACKUP_FILE}")"
    sha256sum "$(basename "${BACKUP_FILE}")" > "$(basename "${BACKUP_FILE}").sha256"
    chmod 600 "$(basename "${BACKUP_FILE}").sha256"
  )
fi

echo "Apagando servicio de base de datos..."
compose_cmd "${ENV_FILE}" down --remove-orphans

echo "Snapshot listo en ${BACKUP_FILE}"
if [[ "$(dirname "${BACKUP_FILE}")" == "${MODE_BACKUP_DIR}" ]]; then
  echo "Alias actualizado en ${LATEST_FILE}"
fi
echo "Servicio detenido"
