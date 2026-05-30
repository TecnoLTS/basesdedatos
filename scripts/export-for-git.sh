#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'USAGE'
Uso: ./scripts/export-for-git.sh <production|development> [etiqueta-destino] [--stage]

Genera un backup cifrado con una clave temporal distinta a la clave normal del
ambiente. El backup queda en git-transfer/ y puede subirse con Git usando
git add -f. La clave temporal nunca se agrega al repo.

Variables opcionales:
  TRANSFER_BACKUP_PASSPHRASE   Clave temporal ya acordada fuera de Git.
USAGE
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

MODE="${1:-production}"
if [[ $# -gt 0 ]]; then
  shift
fi

TARGET_LABEL="transfer"
STAGE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stage)
      STAGE=1
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

require_valid_mode "${MODE}"
ensure_prereqs

TIMESTAMP="$(timestamp_utc)"
SAFE_LABEL="$(printf '%s' "${TARGET_LABEL}" | tr -cs '[:alnum:]_.-' '-')"
TRANSFER_DIR="${APP_DIR}/git-transfer"
SECRETS_DIR="${APP_DIR}/transfer-secrets"
PACKAGE_BASENAME="${MODE}-to-${SAFE_LABEL}-${TIMESTAMP}.sql.enc"
BACKUP_PATH="${TRANSFER_DIR}/${PACKAGE_BASENAME}"
MANIFEST_PATH="${BACKUP_PATH}.manifest"

mkdir -p "${TRANSFER_DIR}" "${SECRETS_DIR}"
chmod 700 "${SECRETS_DIR}"

TRANSFER_PASSPHRASE="${TRANSFER_BACKUP_PASSPHRASE:-}"
PASSPHRASE_FILE=""
if [[ -z "${TRANSFER_PASSPHRASE}" ]]; then
  TRANSFER_PASSPHRASE="$(openssl rand -base64 48)"
  PASSPHRASE_FILE="${SECRETS_DIR}/${PACKAGE_BASENAME}.passphrase"
  umask 077
  printf '%s\n' "${TRANSFER_PASSPHRASE}" > "${PASSPHRASE_FILE}"
fi

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
  "${SCRIPT_DIR}/backup-and-stop.sh" "${MODE}" "${BACKUP_PATH}"

chmod 600 "${BACKUP_PATH}" "${BACKUP_PATH}.sha256"
chmod 644 "${MANIFEST_PATH}"

if [[ "${STAGE}" == "1" ]]; then
  git -C "${APP_DIR}" add -f "${BACKUP_PATH}" "${BACKUP_PATH}.sha256" "${MANIFEST_PATH}"
  echo "Paquete agregado al index de Git."
fi

echo "Paquete listo:"
echo "  ${BACKUP_PATH}"
echo "  ${BACKUP_PATH}.sha256"
echo "  ${MANIFEST_PATH}"

if [[ -n "${PASSPHRASE_FILE}" ]]; then
  echo "Clave temporal guardada localmente, NO la subas a Git:"
  echo "  ${PASSPHRASE_FILE}"
else
  echo "Se uso TRANSFER_BACKUP_PASSPHRASE desde el entorno; no se guardo clave local."
fi

echo "Para subirlo por Git:"
echo "  git add -f ${BACKUP_PATH#${APP_DIR}/} ${BACKUP_PATH#${APP_DIR}/}.sha256 ${MANIFEST_PATH#${APP_DIR}/}"
echo "  git commit -m \"Transfer encrypted ${MODE} database backup ${TIMESTAMP}\""
echo "  git push"
