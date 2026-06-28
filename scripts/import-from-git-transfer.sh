#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'USAGE'
Uso: ./scripts/import-from-git-transfer.sh <git-transfer/backup.sql.enc> [--yes]

Restaura un backup cifrado que llego por Git. Verifica el .sha256 si existe y
pasa la restauracion al resolvedor comun de claves.
El ambiente destino sale de entorno/.env.

Variables opcionales:
  BACKUP_DECRYPTION_PASSPHRASE  Clave del paquete para uso no interactivo.
  TRANSFER_BACKUP_PASSPHRASE    Alias aceptado para la misma clave.
  BACKUP_PASSPHRASE_FILE        Archivo local con la clave, primera linea.
USAGE
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

BACKUP_ARG=""
ASSUME_YES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    qa|production)
      echo "No pases el ambiente al import. El ambiente destino se lee desde entorno/.env." >&2
      usage >&2
      exit 1
      ;;
    --yes|-y)
      ASSUME_YES=1
      ;;
    *)
      if [[ -z "${BACKUP_ARG}" ]]; then
        BACKUP_ARG="$1"
      else
        echo "Argumento no reconocido: $1" >&2
        usage >&2
        exit 1
      fi
      ;;
  esac
  shift
done

if [[ -z "${BACKUP_ARG}" ]]; then
  usage >&2
  exit 1
fi

active_mode_from_env >/dev/null
BACKUP_PATH="$(absolute_app_path "${BACKUP_ARG}")"

if [[ ! -f "${BACKUP_PATH}" ]]; then
  echo "No existe el backup ${BACKUP_PATH}" >&2
  exit 1
fi

if [[ -f "${BACKUP_PATH}.sha256" ]]; then
  (
    cd "$(dirname "${BACKUP_PATH}")"
    sha256sum -c "$(basename "${BACKUP_PATH}").sha256"
  )
else
  echo "Advertencia: no existe checksum ${BACKUP_PATH}.sha256" >&2
fi

RESTORE_ARGS=("${BACKUP_PATH}")
if [[ "${ASSUME_YES}" == "1" ]]; then
  RESTORE_ARGS+=("--yes")
fi

"${SCRIPT_DIR}/restore-from-backup.sh" "${RESTORE_ARGS[@]}"
