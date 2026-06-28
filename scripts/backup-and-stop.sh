#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

umask 077

usage() {
  cat <<'USAGE'
Uso: ./scripts/backup-and-stop.sh [ruta-backup.sql.enc]

El ambiente activo sale de entorno/.env (ENTORNO_MODE=qa|production).
No pases qa ni production como argumento.
USAGE
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

if legacy_mode_arg "${1:-}"; then
  echo "No pases '${1}' al backup. El ambiente se lee desde entorno/.env (ENTORNO_MODE)." >&2
  echo "Uso correcto: ./scripts/backup-and-stop.sh [ruta-backup.sql.enc]" >&2
  exit 1
fi

if [[ "$#" -gt 1 ]]; then
  usage >&2
  exit 1
fi

MODE="$(active_mode_from_env)"
BACKUP_FILE_ARG="${1:-}"
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
  echo "La base principal esta levantada en modo ${running_db_env}, pero entorno/.env indica ${MODE}." >&2
  echo "Ajusta entorno/.env o despliega el ambiente activo antes de respaldar." >&2
  exit 1
fi

echo "Levantando PostgreSQL para exportar el cluster..."
compose_cmd "${ENV_FILE}" up -d --remove-orphans db
wait_for_db "${ENV_FILE}"
assert_db_mode "${ENV_FILE}"

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
