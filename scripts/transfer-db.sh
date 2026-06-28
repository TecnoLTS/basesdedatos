#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'USAGE'
Uso:
  ./scripts/transfer-db.sh export [--label nombre]
  ./scripts/transfer-db.sh restore [git-transfer/backup.sql.enc] [--yes]

Flujo normal:
  1. En origen:  ./scripts/transfer-db.sh export
  2. En destino: ./scripts/transfer-db.sh restore

El ambiente activo sale de entorno/.env.
La clave temporal la eliges en origen y
la vuelves a ingresar en destino. Esa clave no se guarda en Git. El paquete
cifrado queda visible para Git; tu decides cuando hacer commit y push.
USAGE
}

read_transfer_passphrase() {
  local prompt="$1"
  local confirm="${2:-0}"
  local first second

  if [[ ! -t 0 ]]; then
    echo "Este comando necesita una terminal interactiva para pedir la clave temporal." >&2
    echo "Alternativa: exporta TRANSFER_BACKUP_PASSPHRASE antes de ejecutarlo." >&2
    exit 1
  fi

  printf '%s: ' "${prompt}" >&2
  read -r -s first
  echo >&2
  if [[ "${#first}" -lt 5 ]]; then
    echo "La clave temporal debe tener al menos 20 caracteres." >&2
    exit 1
  fi

  if [[ "${confirm}" == "1" ]]; then
    printf '%s' "Repite la clave temporal: " >&2
    read -r -s second
    echo >&2
    if [[ "${first}" != "${second}" ]]; then
      echo "Las claves no coinciden." >&2
      exit 1
    fi
  fi

  printf '%s\n' "${first}"
}

COMMAND="${1:-}"
if [[ -z "${COMMAND}" || "${COMMAND}" == "--help" || "${COMMAND}" == "-h" ]]; then
  usage
  exit 0
fi
shift

LABEL="transfer"
ASSUME_YES=0
BACKUP_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      echo "No uses --mode. El ambiente se lee desde entorno/.env." >&2
      usage >&2
      exit 1
      ;;
    --label)
      LABEL="${2:-}"
      if [[ -z "${LABEL}" ]]; then
        echo "Falta valor para --label" >&2
        exit 1
      fi
      shift
      ;;
    --stage|--publish)
      echo "Aviso: $1 ya no hace git add, commit ni push; el archivo queda para que Git lo detecte." >&2
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

MODE="$(active_mode_from_env)"

case "${COMMAND}" in
  export)
    TRANSFER_PASSPHRASE="${TRANSFER_BACKUP_PASSPHRASE:-}"
    if [[ -z "${TRANSFER_PASSPHRASE}" ]]; then
      echo "Ambiente detectado para exportar: ${MODE}"
      TRANSFER_PASSPHRASE="$(read_transfer_passphrase "Elige una clave temporal para este backup" 1)"
    fi

    TRANSFER_BACKUP_PASSPHRASE="${TRANSFER_PASSPHRASE}" \
      "${SCRIPT_DIR}/export-for-git.sh" --label "${LABEL}"
    ;;
  restore|import)
    if [[ -z "${BACKUP_ARG}" ]]; then
      BACKUP_ARG="$(latest_git_transfer_backup)"
      if [[ -z "${BACKUP_ARG}" ]]; then
        echo "No encontre backups en git-transfer/. Indica la ruta del .sql.enc." >&2
        exit 1
      fi
      echo "Backup detectado: ${BACKUP_ARG#${APP_DIR}/}"
    fi

    TRANSFER_PASSPHRASE="${TRANSFER_BACKUP_PASSPHRASE:-${BACKUP_DECRYPTION_PASSPHRASE:-}}"
    if [[ -z "${TRANSFER_PASSPHRASE}" ]]; then
      echo "Ambiente detectado para restaurar: ${MODE}"
      echo "El restore probara claves locales disponibles y, si hace falta, pedira la clave del backup."
    fi

    args=("${BACKUP_ARG}")
    if [[ "${ASSUME_YES}" == "1" ]]; then
      args+=("--yes")
    fi

    if [[ -n "${TRANSFER_PASSPHRASE}" ]]; then
      TRANSFER_BACKUP_PASSPHRASE="${TRANSFER_PASSPHRASE}" \
        "${SCRIPT_DIR}/import-from-git-transfer.sh" "${args[@]}"
    else
      "${SCRIPT_DIR}/import-from-git-transfer.sh" "${args[@]}"
    fi
    ;;
  *)
    echo "Comando no reconocido: ${COMMAND}" >&2
    usage >&2
    exit 1
    ;;
esac
