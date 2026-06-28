#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'USAGE'
Uso: ./scripts/restore-from-backup.sh [ruta-backup.sql.enc|directorio-backups] [--yes]

Si no indicas archivo, se restaura el .sql.enc local mas reciente disponible,
sin filtrar por nombre ni origen.
El ambiente activo sale de entorno/.env y solo define el destino.
No pases el ambiente como argumento.

Variables opcionales para descifrar:
  BACKUP_DECRYPTION_PASSPHRASE  Clave exacta del backup para uso no interactivo.
  TRANSFER_BACKUP_PASSPHRASE    Alias para uso no interactivo.
  BACKUP_PASSPHRASE_FILE        Archivo local con la clave, primera linea.

--yes solo salta la confirmacion destructiva; no salta la clave del backup.
USAGE
}

BACKUP_FILE_ARG=""
ASSUME_YES="${RESTORE_ASSUME_YES:-0}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    qa|production)
      echo "No pases el ambiente al restore. El ambiente destino se lee desde entorno/.env." >&2
      echo "Uso correcto: ./scripts/restore-from-backup.sh [ruta-backup.sql.enc|directorio-backups] [--yes]" >&2
      exit 1
      ;;
    --yes|-y)
      ASSUME_YES=1
      ;;
    --help|-h)
      usage
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

MODE="$(active_mode_from_env)"
ENV_FILE="$(resolve_env_file "${MODE}")"

ensure_prereqs
load_env_file "${ENV_FILE}"
BACKUP_PASSPHRASE=""

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
  echo "No existe un snapshot local para restaurar." >&2
  echo "Ejecuta primero ./scripts/backup-and-stop.sh o indica la ruta exacta de cualquier .sql.enc." >&2
  exit 1
fi

verify_backup_checksum() {
  local checksum_file="${BACKUP_FILE}.sha256"

  if [[ ! -f "${checksum_file}" ]]; then
    return 0
  fi

  if ! command -v sha256sum >/dev/null 2>&1; then
    echo "Advertencia: existe ${checksum_file}, pero sha256sum no esta disponible." >&2
    return 0
  fi

  (
    cd "$(dirname "${BACKUP_FILE}")"
    sha256sum -c "$(basename "${checksum_file}")"
  )
}

try_decrypt_backup() {
  local passphrase="$1"

  BACKUP_ENCRYPTION_PASSPHRASE="${passphrase}" decrypt_backup_stream < "${BACKUP_FILE}" >/dev/null 2>&1
}

try_passphrase_source() {
  local source="$1"
  local passphrase="$2"

  [[ -n "${passphrase}" ]] || return 1

  if try_decrypt_backup "${passphrase}"; then
    BACKUP_PASSPHRASE="${passphrase}"
    BACKUP_PASSPHRASE_SOURCE="${source}"
    return 0
  fi

  echo "La clave de ${source} no descifra este backup." >&2
  return 1
}

select_backup_passphrase() {
  local entered_passphrase file_passphrase=""

  if [[ -n "${BACKUP_PASSPHRASE_FILE:-}" ]]; then
    if [[ ! -f "${BACKUP_PASSPHRASE_FILE}" ]]; then
      echo "No existe BACKUP_PASSPHRASE_FILE=${BACKUP_PASSPHRASE_FILE}" >&2
      exit 1
    fi
    IFS= read -r file_passphrase < "${BACKUP_PASSPHRASE_FILE}" || true
    if try_passphrase_source "BACKUP_PASSPHRASE_FILE" "${file_passphrase}"; then
      return 0
    fi
  fi

  if try_passphrase_source "BACKUP_DECRYPTION_PASSPHRASE" "${BACKUP_DECRYPTION_PASSPHRASE:-}"; then
    return 0
  fi

  if try_passphrase_source "TRANSFER_BACKUP_PASSPHRASE" "${TRANSFER_BACKUP_PASSPHRASE:-}"; then
    return 0
  fi

  if [[ -t 0 ]]; then
    while true; do
      read -r -s -p "Clave del backup cifrado: " entered_passphrase
      echo
      if [[ -z "${entered_passphrase}" ]]; then
        echo "La clave no puede estar vacia." >&2
        continue
      fi
      if try_decrypt_backup "${entered_passphrase}"; then
        BACKUP_PASSPHRASE="${entered_passphrase}"
        BACKUP_PASSPHRASE_SOURCE="prompt interactivo"
        return 0
      fi
      echo "La clave ingresada no descifra este backup." >&2
    done
  fi

  echo "Falta una clave valida para desencriptar ${BACKUP_FILE}." >&2
  echo "Usa BACKUP_DECRYPTION_PASSPHRASE, TRANSFER_BACKUP_PASSPHRASE o BACKUP_PASSPHRASE_FILE." >&2
  exit 1
}

verify_backup_checksum

echo "Verificando la clave del backup antes de tocar datos..."
select_backup_passphrase
echo "Backup desencriptado correctamente usando ${BACKUP_PASSPHRASE_SOURCE}."

if [[ -z "${BACKUP_PASSPHRASE}" ]]; then
  echo "No se pudo resolver la clave del backup." >&2
  exit 1
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
  echo "El prefijo del backup no cambia el destino; solo cuenta entorno/.env."
  read -r -p "Escribe RESTORE ${MODE} para continuar: " answer
  if [[ "${answer}" != "RESTORE ${MODE}" ]]; then
    echo "Restauracion cancelada" >&2
    exit 1
  fi
}

confirm_restore

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
