#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

umask 077

usage() {
  cat <<'USAGE'
Uso: ./scripts/backup-and-stop.sh [ruta-backup.sql.enc]

El ambiente activo sale de entorno/.env.
No pases el ambiente como argumento.
El comando pide una clave para cifrar el backup y la solicita dos veces.
USAGE
}

read_backup_passphrase() {
  local first second

  if [[ -n "${BACKUP_PASSPHRASE_FILE:-}" ]]; then
    if [[ ! -f "${BACKUP_PASSPHRASE_FILE}" ]]; then
      echo "No existe BACKUP_PASSPHRASE_FILE=${BACKUP_PASSPHRASE_FILE}" >&2
      exit 1
    fi
    IFS= read -r first < "${BACKUP_PASSPHRASE_FILE}" || true
    if [[ -z "${first}" ]]; then
      echo "BACKUP_PASSPHRASE_FILE no puede estar vacio." >&2
      exit 1
    fi
    printf '%s\n' "${first}"
    return 0
  fi

  if [[ -n "${BACKUP_ENCRYPTION_PASSPHRASE_OVERRIDE:-}" ]]; then
    printf '%s\n' "${BACKUP_ENCRYPTION_PASSPHRASE_OVERRIDE}"
    return 0
  fi

  if [[ ! -t 0 ]]; then
    echo "Este backup necesita una terminal interactiva para pedir la clave." >&2
    echo "Alternativa no interactiva: usa BACKUP_PASSPHRASE_FILE con un archivo local seguro." >&2
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

if legacy_mode_arg "${1:-}"; then
  echo "No pases el ambiente al backup. El ambiente se lee desde entorno/.env." >&2
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
BACKUP_PASSPHRASE="$(read_backup_passphrase)"

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
