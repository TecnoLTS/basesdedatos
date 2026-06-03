#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BACKUP_FILE="${BACKUP_FILE:-}"
DATA_DIR="${DATA_DIR:-${APP_DIR}/postgres18_data}"

valid_mode() {
  local mode="$1"

  [[ "${mode}" == "production" || "${mode}" == "development" ]]
}

require_valid_mode() {
  local mode="$1"

  if ! valid_mode "${mode}"; then
    echo "Modo invalido: ${mode}. Usa production o development." >&2
    exit 1
  fi
}

default_data_dir_for_mode() {
  local mode="$1"

  require_valid_mode "${mode}"
  if [[ "${mode}" == "development" ]]; then
    printf '%s\n' "./postgres18_development_data"
  else
    printf '%s\n' "./postgres18_data"
  fi
}

absolute_app_path() {
  local path="$1"

  if [[ "${path}" == /* ]]; then
    printf '%s\n' "${path}"
  else
    printf '%s\n' "${APP_DIR}/${path#./}"
  fi
}

backup_dir_for_mode() {
  local mode="$1"

  require_valid_mode "${mode}"
  printf '%s\n' "${APP_DIR}/backups/${mode}"
}

timestamp_utc() {
  date -u +%Y%m%dT%H%M%SZ
}

default_backup_file_for_mode() {
  local mode="$1"
  local timestamp="${2:-$(timestamp_utc)}"

  printf '%s/%s-%s.sql.enc\n' "$(backup_dir_for_mode "${mode}")" "${mode}" "${timestamp}"
}

latest_backup_file_for_mode() {
  local mode="$1"

  printf '%s/latest.sql.enc\n' "$(backup_dir_for_mode "${mode}")"
}

latest_backup_file_in_dir() {
  local backup_dir="$1"
  local latest_file

  latest_file="$(
    find "${backup_dir}" -maxdepth 1 -type f -name '*.sql.enc' ! -name 'latest.sql.enc' -printf '%T@ %p\n' 2>/dev/null \
      | sort -nr \
      | awk 'NR == 1 {print $2}'
  )"

  if [[ -n "${latest_file}" ]]; then
    printf '%s\n' "${latest_file}"
    return 0
  fi

  if [[ -f "${backup_dir}/latest.sql.enc" || -L "${backup_dir}/latest.sql.enc" ]]; then
    printf '%s\n' "${backup_dir}/latest.sql.enc"
  fi
}

latest_local_backup_file() {
  local latest_file

  latest_file="$(
    find "${APP_DIR}/backups" -mindepth 2 -maxdepth 2 -type f -name '*.sql.enc' ! -name 'latest.sql.enc' -printf '%T@ %p\n' 2>/dev/null \
      | sort -nr \
      | awk 'NR == 1 {print $2}'
  )"

  if [[ -n "${latest_file}" ]]; then
    printf '%s\n' "${latest_file}"
    return 0
  fi

  latest_file="$(
    find "${APP_DIR}/backups" -mindepth 2 -maxdepth 2 \( -type f -o -type l \) -name 'latest.sql.enc' -printf '%T@ %p\n' 2>/dev/null \
      | sort -nr \
      | awk 'NR == 1 {print $2}'
  )"

  if [[ -n "${latest_file}" ]]; then
    printf '%s\n' "${latest_file}"
  fi
}

running_db_env() {
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' next-test-db 2>/dev/null | awk -F= '/^DB_ENV=/{print $2; exit}' || true
}

default_mode() {
  local mode

  mode="$(running_db_env)"
  if valid_mode "${mode}"; then
    printf '%s\n' "${mode}"
    return 0
  fi

  if [[ -f "${APP_DIR}/.env" ]]; then
    mode="$(env_value_from_file "${APP_DIR}/.env" DB_ENV)"
    if valid_mode "${mode}"; then
      printf '%s\n' "${mode}"
      return 0
    fi
  fi

  printf '%s\n' "production"
}

latest_git_transfer_backup() {
  find "${APP_DIR}/git-transfer" -maxdepth 1 -type f -name '*.sql.enc' -printf '%T@ %p\n' 2>/dev/null \
    | sort -nr \
    | awk 'NR == 1 {print $2}'
}

env_value_from_file() {
  local env_file="$1"
  local key="$2"

  (
    set -a
    # shellcheck disable=SC1090
    source "${env_file}"
    set +a
    printf '%s\n' "${!key:-}"
  )
}

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

  if ! docker network inspect paramascotasec-db-internal >/dev/null 2>&1; then
    docker network create --internal paramascotasec-db-internal >/dev/null
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
  require_valid_mode "${mode}"

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
    upsert_env_value "${env_file}" "POSTGRES_DATA_DIR" "$(default_data_dir_for_mode "${mode}")"

    printf '%s\n' "${env_file}"
    return 0
  fi

  if [[ -f "${APP_DIR}/.env" ]]; then
    upsert_env_value "${APP_DIR}/.env" "DB_ENV" "production"
    upsert_env_value "${APP_DIR}/.env" "POSTGRES_DATA_DIR" "$(default_data_dir_for_mode "${mode}")"
    printf '%s\n' "${APP_DIR}/.env"
    return 0
  fi

  if [[ -f "${APP_DIR}/.env.example" ]]; then
    cp "${APP_DIR}/.env.example" "${APP_DIR}/.env"
    echo "Se creo ${APP_DIR}/.env desde .env.example. Ajusta credenciales si hace falta."
    upsert_env_value "${APP_DIR}/.env" "DB_ENV" "production"
    upsert_env_value "${APP_DIR}/.env" "POSTGRES_DATA_DIR" "$(default_data_dir_for_mode "${mode}")"
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

  POSTGRES_DATA_DIR="${POSTGRES_DATA_DIR:-./postgres18_data}"
  DATA_DIR="$(absolute_app_path "${POSTGRES_DATA_DIR}")"
  export POSTGRES_DATA_DIR DATA_DIR
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
    if compose_cmd "${env_file}" exec -T -e PGPASSWORD="${POSTGRES_PASSWORD}" db \
      pg_isready -h 127.0.0.1 -U "${POSTGRES_USER}" -d postgres >/dev/null 2>&1; then
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
