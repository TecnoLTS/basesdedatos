#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'USAGE'
Uso: ./scripts/import-between-envs.sh <origen> <destino> [--yes]

Ejemplos:
  ./scripts/import-between-envs.sh development production
  ./scripts/import-between-envs.sh production development --yes

El script genera un backup cifrado del origen, detiene ese ambiente y restaura
el snapshot en el destino. Si origen y destino usan claves distintas, toma la
clave de desencriptado desde el .env del origen.
USAGE
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

SOURCE_MODE="${1:-}"
TARGET_MODE="${2:-}"
ASSUME_YES=0

shift $(( $# >= 2 ? 2 : $# ))
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y)
      ASSUME_YES=1
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Argumento no reconocido: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

if [[ -z "${SOURCE_MODE}" || -z "${TARGET_MODE}" ]]; then
  usage >&2
  exit 1
fi

require_valid_mode "${SOURCE_MODE}"
require_valid_mode "${TARGET_MODE}"

if [[ "${SOURCE_MODE}" == "${TARGET_MODE}" ]]; then
  echo "Origen y destino no pueden ser el mismo ambiente. Usa restore-from-backup.sh para restaurar en el mismo ambiente." >&2
  exit 1
fi

confirm_import() {
  if [[ "${ASSUME_YES}" == "1" ]]; then
    return 0
  fi

  if [[ ! -t 0 ]]; then
    echo "La importacion reemplaza completamente ${TARGET_MODE}. Ejecuta con --yes si ya validaste la operacion." >&2
    exit 1
  fi

  echo "ATENCION: se generara un backup de ${SOURCE_MODE} y se reemplazara completamente ${TARGET_MODE}."
  echo "El contenedor se recreara porque este proyecto usa un unico nombre de servicio."
  read -r -p "Escribe IMPORT ${SOURCE_MODE} TO ${TARGET_MODE} para continuar: " answer
  if [[ "${answer}" != "IMPORT ${SOURCE_MODE} TO ${TARGET_MODE}" ]]; then
    echo "Importacion cancelada" >&2
    exit 1
  fi
}

ensure_prereqs
SOURCE_ENV_FILE="$(resolve_env_file "${SOURCE_MODE}")"
resolve_env_file "${TARGET_MODE}" >/dev/null
SOURCE_BACKUP_PASSPHRASE="$(env_value_from_file "${SOURCE_ENV_FILE}" BACKUP_ENCRYPTION_PASSPHRASE)"
SOURCE_DATA_DIR="$(absolute_app_path "$(env_value_from_file "${SOURCE_ENV_FILE}" POSTGRES_DATA_DIR)")"

if [[ -z "${SOURCE_BACKUP_PASSPHRASE}" ]]; then
  echo "Falta BACKUP_ENCRYPTION_PASSPHRASE en ${SOURCE_ENV_FILE}" >&2
  exit 1
fi

if [[ ! -f "${SOURCE_DATA_DIR}/18/docker/PG_VERSION" ]]; then
  echo "El ambiente origen ${SOURCE_MODE} no tiene un cluster PostgreSQL inicializado en ${SOURCE_DATA_DIR}." >&2
  echo "No se importara una base vacia por seguridad. Restaura o despliega ${SOURCE_MODE} antes de usarlo como origen." >&2
  exit 1
fi

confirm_import

current_env="$(running_db_env)"
if [[ -n "${current_env}" && "${current_env}" != "${SOURCE_MODE}" ]]; then
  echo "Deteniendo ambiente activo ${current_env} para respaldar ${SOURCE_MODE}..."
  compose_cmd "${SOURCE_ENV_FILE}" down --remove-orphans
fi

BACKUP_PATH="$(default_backup_file_for_mode "${SOURCE_MODE}")"
echo "Generando backup de ${SOURCE_MODE} en ${BACKUP_PATH}..."
BACKUP_FILE="${BACKUP_PATH}" "${SCRIPT_DIR}/backup-and-stop.sh" "${SOURCE_MODE}"

echo "Restaurando backup de ${SOURCE_MODE} en ${TARGET_MODE}..."
BACKUP_DECRYPTION_PASSPHRASE="${SOURCE_BACKUP_PASSPHRASE}" \
RESTORE_ASSUME_YES=1 \
BACKUP_FILE="${BACKUP_PATH}" \
  "${SCRIPT_DIR}/restore-from-backup.sh" "${TARGET_MODE}" "${BACKUP_PATH}" --yes

echo "Importacion ${SOURCE_MODE} -> ${TARGET_MODE} completada"
