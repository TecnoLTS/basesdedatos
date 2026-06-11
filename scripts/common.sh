#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BACKUP_FILE="${BACKUP_FILE:-}"
DATA_DIR="${DATA_DIR:-${APP_DIR}/postgres18_data}"
ENTORNO_DIR="${APP_DIR}/entorno"
ENTORNO_ENV_FILE="${ENTORNO_DIR}/.env"
TEMPLATE_ENTORNO_DIR="${APP_DIR}/templates/entorno"

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

  if [[ -f "${ENTORNO_ENV_FILE}" ]]; then
    mode="$(env_value_from_file "${ENTORNO_ENV_FILE}" ENTORNO_MODE)"
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

  awk -v target="${key}" -F= '
    $0 !~ /^[[:space:]]*#/ && $1 == target {
      value = substr($0, index($0, "=") + 1)
      sub(/\r$/, "", value)
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      if ((value ~ /^".*"$/) || (value ~ /^'\''.*'\''$/)) {
        value = substr(value, 2, length(value) - 2)
      }
      print value
      exit
    }
  ' "${env_file}" 2>/dev/null || true
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

ensure_entorno_files() {
  local created=0

  mkdir -p "${ENTORNO_DIR}"

  if [[ ! -f "${ENTORNO_ENV_FILE}" ]]; then
    if [[ ! -f "${TEMPLATE_ENTORNO_DIR}/.env.example" ]]; then
      echo "No se encontro ${TEMPLATE_ENTORNO_DIR}/.env.example" >&2
      exit 1
    fi
    cp "${TEMPLATE_ENTORNO_DIR}/.env.example" "${ENTORNO_ENV_FILE}"
    chmod 600 "${ENTORNO_ENV_FILE}"
    echo "Se creo ${ENTORNO_ENV_FILE} desde templates/entorno/.env.example."
    created=1
  fi

  if [[ "${created}" == "1" ]]; then
    echo "Completa valores reales y ENTORNO_MODE en entorno/.env antes de desplegar." >&2
    exit 1
  fi
}

assert_no_legacy_runtime_paths() {
  local env_name=".env"
  local suffix
  local found=()
  local path

  for suffix in "" ".development" ".production" ".local"; do
    path="${APP_DIR}/${env_name}${suffix}"
    if [[ -e "${path}" ]]; then
      found+=("${path#${APP_DIR}/}")
    fi
  done

  if (( ${#found[@]} > 0 )); then
    printf 'Rutas legacy fuera de entorno/ detectadas en paramascotasec-DB: %s\n' "${found[*]}" >&2
    printf 'Ejecuta scripts/migrate-entorno.sh o mueve esos archivos a un backup externo antes de desplegar.\n' >&2
    exit 1
  fi
}

assert_entorno_mode() {
  local expected="$1"
  local actual

  actual="$(env_value_from_file "${ENTORNO_ENV_FILE}" ENTORNO_MODE)"

  if [[ "${actual}" != "${expected}" ]]; then
    echo "ENTORNO_MODE=${actual:-<vacio>} en ${ENTORNO_ENV_FILE}; esperado ${expected}." >&2
    exit 1
  fi
}

resolve_env_file() {
  local mode="${1:-production}"
  local env_file="${ENTORNO_ENV_FILE}"
  require_valid_mode "${mode}"
  assert_no_legacy_runtime_paths
  ensure_entorno_files
  assert_entorno_mode "${mode}"

  if [[ "${mode}" == "development" ]]; then
    upsert_env_value "${env_file}" "POSTGRES_BIND_IP" "127.0.0.1"
    upsert_env_value "${env_file}" "DB_ENV" "development"
    upsert_env_value "${env_file}" "POSTGRES_DATA_DIR" "$(default_data_dir_for_mode "${mode}")"

    printf '%s\n' "${env_file}"
    return 0
  fi

  upsert_env_value "${env_file}" "DB_ENV" "production"
  upsert_env_value "${env_file}" "POSTGRES_DATA_DIR" "$(default_data_dir_for_mode "${mode}")"
  printf '%s\n' "${env_file}"
  return 0
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
  sync_backend_runtime_role "${mode}" "${env_file}"
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

sync_backend_runtime_role() {
  local mode="$1"
  local env_file="$2"
  local backend_env_file
  local backend_db_name
  local backend_db_user
  local backend_db_password
  local role_exists

  require_valid_mode "${mode}"

  backend_env_file="${APP_DIR}/../paramascotasec-backend/entorno/.env"

  if [[ ! -f "${backend_env_file}" ]]; then
    echo "Aviso: no se encontro ${backend_env_file}; omitiendo ajuste del rol runtime del backend."
    return 0
  fi

  backend_db_name="$(env_value_from_file "${backend_env_file}" DB_DATABASE)"
  backend_db_user="$(env_value_from_file "${backend_env_file}" DB_USERNAME)"
  backend_db_password="$(env_value_from_file "${backend_env_file}" DB_PASSWORD)"

  if [[ -z "${backend_db_name}" || -z "${backend_db_user}" || -z "${backend_db_password}" ]]; then
    echo "Aviso: faltan DB_DATABASE, DB_USERNAME o DB_PASSWORD en ${backend_env_file}; omitiendo ajuste del rol runtime del backend."
    return 0
  fi

  if [[ ! "${backend_db_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ || ! "${backend_db_user}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "Nombre de DB o rol backend no seguro para ajustar automaticamente: ${backend_db_name}/${backend_db_user}" >&2
    exit 1
  fi

  echo "Alineando rol runtime del backend para ${backend_db_name}..."

  role_exists="$(
    compose_cmd "${env_file}" exec -T -e PGPASSWORD="${POSTGRES_PASSWORD}" db \
      psql -h 127.0.0.1 -U "${POSTGRES_USER}" -d postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname = '${backend_db_user}'"
  )"

  if [[ "${role_exists}" == "1" ]]; then
    compose_cmd "${env_file}" exec -T -e PGPASSWORD="${POSTGRES_PASSWORD}" db \
      psql -h 127.0.0.1 -U "${POSTGRES_USER}" -d postgres -v ON_ERROR_STOP=1 -v backend_db_password="${backend_db_password}" >/dev/null <<SQL
ALTER ROLE "${backend_db_user}" WITH LOGIN PASSWORD :'backend_db_password';
SQL
  else
    compose_cmd "${env_file}" exec -T -e PGPASSWORD="${POSTGRES_PASSWORD}" db \
      psql -h 127.0.0.1 -U "${POSTGRES_USER}" -d postgres -v ON_ERROR_STOP=1 -v backend_db_password="${backend_db_password}" >/dev/null <<SQL
CREATE ROLE "${backend_db_user}" WITH LOGIN PASSWORD :'backend_db_password';
SQL
  fi

  compose_cmd "${env_file}" exec -T -e PGPASSWORD="${POSTGRES_PASSWORD}" db \
    psql -h 127.0.0.1 -U "${POSTGRES_USER}" -d postgres -v ON_ERROR_STOP=1 >/dev/null <<SQL
GRANT CONNECT ON DATABASE "${backend_db_name}" TO "${backend_db_user}";
SQL

  compose_cmd "${env_file}" exec -T -e PGPASSWORD="${POSTGRES_PASSWORD}" db \
    psql -h 127.0.0.1 -U "${POSTGRES_USER}" -d "${backend_db_name}" -v ON_ERROR_STOP=1 >/dev/null <<SQL
GRANT USAGE ON SCHEMA public TO "${backend_db_user}";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO "${backend_db_user}";
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO "${backend_db_user}";
SQL
}
