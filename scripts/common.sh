#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BACKUP_FILE="${BACKUP_FILE:-${APP_DIR}/backups/backup.sql.enc}"
DATA_DIR="${DATA_DIR:-${APP_DIR}/postgres16_data}"

ensure_prereqs() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "docker no esta instalado"
    exit 1
  fi

  if ! docker compose version >/dev/null 2>&1; then
    echo "docker compose no esta disponible"
    exit 1
  fi

  if ! command -v openssl >/dev/null 2>&1; then
    echo "openssl no esta instalado"
    exit 1
  fi

  if ! docker network inspect edge >/dev/null 2>&1; then
    docker network create edge >/dev/null
  fi
}

upsert_env_value() {
  local file="$1"
  local key="$2"
  local value="$3"

  python3 - "$file" "$key" "$value" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
key = sys.argv[2]
value = sys.argv[3]
lines = path.read_text().splitlines()
for index, line in enumerate(lines):
    if line.startswith(f"{key}="):
        lines[index] = f"{key}={value}"
        break
else:
    lines.append(f"{key}={value}")
path.write_text("\n".join(lines) + "\n")
PY
}

resolve_env_file() {
  local mode="${1:-production}"

  if [[ "${mode}" == "development" ]]; then
    local env_file="${APP_DIR}/.env.development"
    if [[ ! -f "${env_file}" ]]; then
      if [[ -f "${APP_DIR}/.env.development.example" ]]; then
        cp "${APP_DIR}/.env.development.example" "${env_file}"
        echo "Se creo ${env_file} desde .env.development.example."
      elif [[ -f "${APP_DIR}/.env" ]]; then
        cp "${APP_DIR}/.env" "${env_file}"
        echo "Se creo ${env_file} desde .env para separar desarrollo de produccion."
      elif [[ -f "${APP_DIR}/.env.example" ]]; then
        cp "${APP_DIR}/.env.example" "${env_file}"
        echo "Se creo ${env_file} desde .env.example."
      else
        echo "No se encontro .env, .env.development.example ni .env.example en ${APP_DIR}" >&2
        exit 1
      fi
    fi

    upsert_env_value "${env_file}" "POSTGRES_BIND_IP" "127.0.0.1"
    upsert_env_value "${env_file}" "DB_ENV" "development"

    printf '%s\n' "${env_file}"
    return 0
  fi

  if [[ -f "${APP_DIR}/.env" ]]; then
    upsert_env_value "${APP_DIR}/.env" "DB_ENV" "production"
    printf '%s\n' "${APP_DIR}/.env"
    return 0
  fi

  if [[ -f "${APP_DIR}/.env.example" ]]; then
    cp "${APP_DIR}/.env.example" "${APP_DIR}/.env"
    echo "Se creo ${APP_DIR}/.env desde .env.example. Ajusta credenciales si hace falta."
    upsert_env_value "${APP_DIR}/.env" "DB_ENV" "production"
    printf '%s\n' "${APP_DIR}/.env"
    return 0
  fi

  echo "No se encontro .env ni .env.example en ${APP_DIR}" >&2
  exit 1
}

load_env_file() {
  local env_file="$1"

  set -a
  # shellcheck disable=SC1090
  source "${env_file}"
  set +a

  : "${POSTGRES_USER:?Falta POSTGRES_USER en ${env_file}}"
  : "${POSTGRES_PASSWORD:?Falta POSTGRES_PASSWORD en ${env_file}}"
  : "${POSTGRES_DB:?Falta POSTGRES_DB en ${env_file}}"
  : "${BACKUP_ENCRYPTION_PASSPHRASE:?Falta BACKUP_ENCRYPTION_PASSPHRASE en ${env_file}}"
}

assert_db_mode() {
  local mode="${1:-production}"
  local container_env

  container_env="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' next-test-db 2>/dev/null | awk -F= '/^DB_ENV=/{print $2; exit}')"
  if [[ "${container_env}" != "${mode}" ]]; then
    echo "La base de datos quedo en DB_ENV=${container_env:-desconocido}, esperado ${mode}" >&2
    exit 1
  fi
}

compose_cmd() {
  local env_file="$1"
  shift

  (
    cd "${APP_DIR}"
    docker compose --env-file "${env_file}" "$@"
  )
}

wait_for_db() {
  local env_file="$1"
  local attempts="${2:-60}"
  local i

  for ((i = 1; i <= attempts; i++)); do
    if compose_cmd "${env_file}" exec -T db pg_isready -U "${POSTGRES_USER}" -d postgres >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  echo "PostgreSQL no quedo listo a tiempo" >&2
  exit 1
}

deploy_database() {
  local mode="${1:-production}"
  local env_file

  ensure_prereqs
  env_file="$(resolve_env_file "${mode}")"
  load_env_file "${env_file}"

  echo "Levantando PostgreSQL en ${mode} usando ${env_file}..."
  compose_cmd "${env_file}" up -d --force-recreate --remove-orphans db
  wait_for_db "${env_file}"
  assert_db_mode "${mode}"
  compose_cmd "${env_file}" ps
  echo "Base de datos ${mode} lista"
}

reset_data_dir() {
  mkdir -p "${DATA_DIR}"

  if [[ "${DATA_DIR}" == "/" || "${DATA_DIR}" == "${APP_DIR}" || "${DATA_DIR}" == "" ]]; then
    echo "DATA_DIR invalido: ${DATA_DIR}" >&2
    exit 1
  fi

  find "${DATA_DIR}" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
}

normalize_dump_stream() {
  sed \
    -e '/^DROP ROLE IF EXISTS postgres;$/d' \
    -e '/^CREATE ROLE postgres;$/d' \
    -e '/^ALTER ROLE postgres WITH /d'
}

encrypt_backup_stream() {
  openssl enc -aes-256-cbc -pbkdf2 -salt -pass env:BACKUP_ENCRYPTION_PASSPHRASE
}

decrypt_backup_stream() {
  openssl enc -d -aes-256-cbc -pbkdf2 -pass env:BACKUP_ENCRYPTION_PASSPHRASE
}
