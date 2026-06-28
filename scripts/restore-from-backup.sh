#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

MODE="$(default_mode)"
BACKUP_FILE_ARG=""
ASSUME_YES="${RESTORE_ASSUME_YES:-0}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    qa|production)
      MODE="$1"
      ;;
    --yes|-y)
      ASSUME_YES=1
      ;;
    --help|-h)
      echo "Uso: $0 [qa|production] [ruta-backup.sql.enc|directorio-backups] [--yes]"
      echo "Si no indicas archivo, se restaura el .sql.enc mas reciente de backups/."
      exit 0
      ;;
    *)
      if [[ -z "${BACKUP_FILE_ARG}" ]]; then
        BACKUP_FILE_ARG="$1"
      else
        echo "Argumento no reconocido: $1" >&2
        exit 1
      fi
      ;;
  esac
  shift
done

require_valid_mode "${MODE}"
MODE="$(canonical_env_mode "${MODE}")"
ENV_FILE="$(resolve_env_file "${MODE}")"

ensure_prereqs
load_env_file "${ENV_FILE}"
BACKUP_PASSPHRASE="${BACKUP_DECRYPTION_PASSPHRASE:-}"

if [[ -z "${BACKUP_FILE}" ]]; then
  if [[ -n "${BACKUP_FILE_ARG}" ]]; then
    BACKUP_FILE="$(absolute_app_path "${BACKUP_FILE_ARG}")"
    if [[ -d "${BACKUP_FILE}" ]]; then
      BACKUP_FILE="$(latest_backup_file_in_dir "${BACKUP_FILE}")"
    fi
  else
    BACKUP_FILE="$(latest_local_backup_file)"
  fi
fi

if [[ -z "${BACKUP_FILE}" || ! -f "${BACKUP_FILE}" ]]; then
  echo "No existe un snapshot para restaurar. Ejecuta primero ./scripts/backup-and-stop.sh qa o production." >&2
  exit 1
fi

if [[ -z "${BACKUP_PASSPHRASE}" ]]; then
  if [[ ! -t 0 ]]; then
    echo "Falta BACKUP_DECRYPTION_PASSPHRASE con la clave del backup." >&2
    exit 1
  fi
  read -r -s -p "Clave del backup cifrado: " BACKUP_PASSPHRASE
  echo
fi

confirm_restore() {
  if [[ "${ASSUME_YES}" == "1" ]]; then
    return 0
  fi

  if [[ ! -t 0 ]]; then
    echo "La restauracion destruye el directorio destino ${DATA_DIR}. Ejecuta con --yes si ya validaste el backup." >&2
    exit 1
  fi

  echo "ATENCION: se reemplazara completamente la base ${MODE} en ${DATA_DIR}."
  echo "Backup origen: ${BACKUP_FILE}"
  read -r -p "Escribe RESTORE ${MODE} para continuar: " answer
  if [[ "${answer}" != "RESTORE ${MODE}" ]]; then
    echo "Restauracion cancelada" >&2
    exit 1
  fi
}

confirm_restore

echo "Verificando que el backup se pueda desencriptar antes de limpiar ${MODE}..."
BACKUP_ENCRYPTION_PASSPHRASE="${BACKUP_PASSPHRASE}" decrypt_backup_stream < "${BACKUP_FILE}" >/dev/null

RESTORE_ROLE="codex_restore_$(date +%s)"
RESTORE_DB="${RESTORE_ROLE}_db"
RESTORE_PASSWORD="$(openssl rand -hex 32)"

cleanup_restore_artifacts() {
  compose_cmd "${ENV_FILE}" exec -T -e PGPASSWORD="${POSTGRES_PASSWORD}" db \
    psql -h 127.0.0.1 -v ON_ERROR_STOP=1 -U "${POSTGRES_USER}" -d postgres -c "DROP DATABASE IF EXISTS ${RESTORE_DB};" >/dev/null 2>&1 || true
  compose_cmd "${ENV_FILE}" exec -T -e PGPASSWORD="${POSTGRES_PASSWORD}" db \
    psql -h 127.0.0.1 -v ON_ERROR_STOP=1 -U "${POSTGRES_USER}" -d postgres -c "DROP ROLE IF EXISTS ${RESTORE_ROLE};" >/dev/null 2>&1 || true
}

trap cleanup_restore_artifacts EXIT

echo "Recreando servicio PostgreSQL desde ${BACKUP_FILE}..."
compose_cmd "${ENV_FILE}" down --remove-orphans
reset_data_dir
compose_cmd "${ENV_FILE}" up -d --remove-orphans db
wait_for_db "${ENV_FILE}"

echo "Creando rol temporal de restauracion..."
compose_cmd "${ENV_FILE}" exec -T -e PGPASSWORD="${POSTGRES_PASSWORD}" db \
  psql -h 127.0.0.1 -v ON_ERROR_STOP=1 -U "${POSTGRES_USER}" -d postgres -c "CREATE ROLE ${RESTORE_ROLE} WITH LOGIN SUPERUSER PASSWORD '${RESTORE_PASSWORD}';"
compose_cmd "${ENV_FILE}" exec -T -e PGPASSWORD="${POSTGRES_PASSWORD}" db \
  psql -h 127.0.0.1 -v ON_ERROR_STOP=1 -U "${POSTGRES_USER}" -d postgres -c "CREATE DATABASE ${RESTORE_DB} OWNER ${RESTORE_ROLE};"

echo "Restaurando cluster completo desde backup cifrado..."
BACKUP_ENCRYPTION_PASSPHRASE="${BACKUP_PASSPHRASE}" decrypt_backup_stream < "${BACKUP_FILE}" \
  | normalize_dump_stream \
  | compose_cmd "${ENV_FILE}" exec -T -e PGPASSWORD="${RESTORE_PASSWORD}" db psql -h 127.0.0.1 -v ON_ERROR_STOP=1 -U "${RESTORE_ROLE}" -d "${RESTORE_DB}"

echo "Eliminando rol temporal de restauracion..."
cleanup_restore_artifacts
trap - EXIT

sync_backend_runtime_role "${MODE}" "${ENV_FILE}"

echo "Verificando estado del servicio..."
compose_cmd "${ENV_FILE}" exec -T -e PGPASSWORD="${POSTGRES_PASSWORD}" db pg_isready -h 127.0.0.1 -U "${POSTGRES_USER}" -d postgres >/dev/null
compose_cmd "${ENV_FILE}" ps

echo "Base de datos restaurada desde backup"
