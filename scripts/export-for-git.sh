#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'USAGE'
Uso: ./scripts/export-for-git.sh [--label etiqueta-destino]

Genera un backup cifrado con la clave que escribas en la terminal. El backup
queda en git-transfer/ para que Git detecte el cambio. La clave nunca se agrega
al repo.
El ambiente activo sale de entorno/.env.

Variables opcionales:
  TRANSFER_BACKUP_PASSPHRASE   Clave para uso no interactivo.
USAGE
}

read_export_passphrase() {
  local first second

  if [[ -n "${TRANSFER_BACKUP_PASSPHRASE:-}" ]]; then
    printf '%s\n' "${TRANSFER_BACKUP_PASSPHRASE}"
    return 0
  fi

  if [[ ! -t 0 ]]; then
    echo "Este export necesita una terminal interactiva para pedir la clave." >&2
    echo "Alternativa no interactiva: exporta TRANSFER_BACKUP_PASSPHRASE." >&2
    exit 1
  fi

  read -r -s -p "Clave para cifrar este backup: " first
  echo >&2
  read -r -s -p "Repite la clave del backup: " second
  echo >&2

  if [[ -z "${first}" ]]; then
    echo "La clave del backup no puede estar vacia." >&2
    exit 1
  fi

  if [[ "${first}" != "${second}" ]]; then
    echo "Las claves no coinciden; no se genero ningun backup." >&2
    exit 1
  fi

  printf '%s\n' "${first}"
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

TARGET_LABEL="transfer"

while [[ $# -gt 0 ]]; do
  case "$1" in
    qa|production)
      echo "No pases el ambiente al export. El ambiente se lee desde entorno/.env." >&2
      usage >&2
      exit 1
      ;;
    --label)
      TARGET_LABEL="${2:-}"
      if [[ -z "${TARGET_LABEL}" ]]; then
        echo "Falta valor para --label" >&2
        exit 1
      fi
      shift
      ;;
    --stage|--publish)
      echo "Aviso: $1 ya no hace git add, commit ni push; el archivo queda para que Git lo detecte." >&2
      ;;
    *)
      if [[ "${TARGET_LABEL}" == "transfer" ]]; then
        TARGET_LABEL="$1"
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
ensure_prereqs

TIMESTAMP="$(timestamp_utc)"
SAFE_LABEL="$(printf '%s' "${TARGET_LABEL}" | tr -cs '[:alnum:]_.-' '-')"
TRANSFER_DIR="${APP_DIR}/git-transfer"
PACKAGE_BASENAME="backup-${SAFE_LABEL}-${TIMESTAMP}.sql.enc"
BACKUP_PATH="${TRANSFER_DIR}/${PACKAGE_BASENAME}"
MANIFEST_PATH="${BACKUP_PATH}.manifest"

mkdir -p "${TRANSFER_DIR}"
TRANSFER_PASSPHRASE="$(read_export_passphrase)"

cat > "${MANIFEST_PATH}" <<EOF
source_mode=${MODE}
target_label=${SAFE_LABEL}
created_at_utc=${TIMESTAMP}
backup_file=${PACKAGE_BASENAME}
checksum_file=${PACKAGE_BASENAME}.sha256
encryption=openssl enc -aes-256-cbc -pbkdf2 -salt
restore_script=./scripts/import-from-git-transfer.sh
EOF

echo "Generando paquete cifrado para Git en ${BACKUP_PATH}..."
BACKUP_FILE="${BACKUP_PATH}" \
BACKUP_ENCRYPTION_PASSPHRASE_OVERRIDE="${TRANSFER_PASSPHRASE}" \
  "${SCRIPT_DIR}/backup-and-stop.sh" "${BACKUP_PATH}"

chmod 600 "${BACKUP_PATH}" "${BACKUP_PATH}.sha256"
chmod 644 "${MANIFEST_PATH}"

echo "Paquete listo:"
echo "  ${BACKUP_PATH}"
echo "  ${BACKUP_PATH}.sha256"
echo "  ${MANIFEST_PATH}"

echo "Git detectara estos archivos; decide luego si haces commit y push."
