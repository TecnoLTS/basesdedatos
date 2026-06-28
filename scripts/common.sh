#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKSPACE_ENV_MODE="${APP_DIR}/../scripts/env-mode.sh"
# shellcheck disable=SC1090
source "${WORKSPACE_ENV_MODE}"
BACKUP_FILE="${BACKUP_FILE:-}"
DATA_DIR="${DATA_DIR:-${APP_DIR}/postgres18_data}"
ENTORNO_DIR="${APP_DIR}/entorno"
ENTORNO_ENV_FILE="${ENTORNO_DIR}/.env"
TEMPLATE_ENTORNO_DIR="${APP_DIR}/templates/entorno"
MODULE_DATABASES_REGISTRY_FILE="${APP_DIR}/config/module-databases.json"

valid_mode() {
  local mode="$1"

  canonical_env_mode "${mode}" >/dev/null 2>&1
}

require_valid_mode() {
  local mode="$1"

  if ! valid_mode "${mode}"; then
    echo "Modo invalido: ${mode}. Usa qa o production." >&2
    exit 1
  fi
}

default_data_dir_for_mode() {
  local mode="$1"

  require_valid_mode "${mode}"
  mode="$(canonical_env_mode "${mode}")"
  if [[ "${mode}" == "qa" ]]; then
    printf '%s\n' "./postgres18_qa_data"
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

safe_identifier() {
  local value="$1"
  [[ "${value}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

module_database_specs() {
  python3 - "$MODULE_DATABASES_REGISTRY_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], 'r', encoding='utf-8') as fh:
    registry = json.load(fh)

for entry in registry.get('databases', []):
    roles = []
    runtime_role = entry.get('runtimeRole') or {}
    if runtime_role:
        roles.append(('true', runtime_role))
    for role in entry.get('additionalRuntimeRoles') or []:
        if role:
            roles.append(('false', role))

    for owner_flag, role in roles:
        print('\t'.join([
            entry.get('moduleKey', ''),
            entry.get('databaseName', ''),
            role.get('source', ''),
            'true' if role.get('optional', False) else 'false',
            role.get('envFile', ''),
            role.get('databaseKey', ''),
            role.get('usernameKey', ''),
            role.get('passwordKey', ''),
            owner_flag,
        ]))
PY
}

backup_dir_for_mode() {
  local mode="$1"

  require_valid_mode "${mode}"
  printf '%s\n' "${APP_DIR}/backups"
}

timestamp_utc() {
  date -u +%Y%m%dT%H%M%SZ
}

default_backup_file_for_mode() {
  local mode="$1"
  local timestamp="${2:-$(timestamp_utc)}"

  require_valid_mode "${mode}"
  printf '%s/backup-%s.sql.enc\n' "$(backup_dir_for_mode "${mode}")" "${timestamp}"
}

latest_backup_file_for_mode() {
  local mode="$1"

  require_valid_mode "${mode}"
  printf '%s/latest.sql.enc\n' "$(backup_dir_for_mode "${mode}")"
}

latest_backup_file_in_dir() {
  local backup_dir="$1"
  local latest_file

  latest_file="$(
    find "${backup_dir}" -maxdepth 1 -type f -name '*.sql.enc' ! -name 'latest.sql.enc' ! -name '*-latest.sql.enc' -printf '%T@ %p\n' 2>/dev/null \
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
  local mode="${1:-}"
  local latest_file

  if valid_mode "${mode}"; then
    mode="$(canonical_env_mode "${mode}")"

    latest_file="$(
      find "${APP_DIR}/backups" -maxdepth 1 -type f -name 'backup-*.sql.enc' ! -name 'latest.sql.enc' -printf '%T@ %p\n' 2>/dev/null \
        | sort -nr \
        | awk 'NR == 1 {print $2}'
    )"

    if [[ -n "${latest_file}" ]]; then
      printf '%s\n' "${latest_file}"
      return 0
    fi

    if [[ -f "${APP_DIR}/backups/latest.sql.enc" || -L "${APP_DIR}/backups/latest.sql.enc" ]]; then
      printf '%s\n' "${APP_DIR}/backups/latest.sql.enc"
      return 0
    fi

    latest_file="$(
      find "${APP_DIR}/backups" -maxdepth 1 -type f -name "${mode}-*.sql.enc" ! -name "${mode}-latest.sql.enc" -printf '%T@ %p\n' 2>/dev/null \
        | sort -nr \
        | awk 'NR == 1 {print $2}'
    )"

    if [[ -n "${latest_file}" ]]; then
      printf '%s\n' "${latest_file}"
      return 0
    fi

    if [[ -f "${APP_DIR}/backups/${mode}-latest.sql.enc" || -L "${APP_DIR}/backups/${mode}-latest.sql.enc" ]]; then
      printf '%s\n' "${APP_DIR}/backups/${mode}-latest.sql.enc"
      return 0
    fi

    latest_file="$(
      find "${APP_DIR}/backups/${mode}" -maxdepth 1 -type f -name '*.sql.enc' ! -name 'latest.sql.enc' -printf '%T@ %p\n' 2>/dev/null \
        | sort -nr \
        | awk 'NR == 1 {print $2}'
    )"

    if [[ -n "${latest_file}" ]]; then
      printf '%s\n' "${latest_file}"
      return 0
    fi

    if [[ -f "${APP_DIR}/backups/${mode}/latest.sql.enc" || -L "${APP_DIR}/backups/${mode}/latest.sql.enc" ]]; then
      printf '%s\n' "${APP_DIR}/backups/${mode}/latest.sql.enc"
    fi

    return 0
  fi

  latest_file="$(
    find "${APP_DIR}/backups" -maxdepth 1 -type f -name '*.sql.enc' ! -name 'latest.sql.enc' ! -name '*-latest.sql.enc' -printf '%T@ %p\n' 2>/dev/null \
      | sort -nr \
      | awk 'NR == 1 {print $2}'
  )"

  if [[ -n "${latest_file}" ]]; then
    printf '%s\n' "${latest_file}"
    return 0
  fi

  latest_file="$(
    find "${APP_DIR}/backups" -maxdepth 1 \( -type f -o -type l \) -name 'latest.sql.enc' -printf '%T@ %p\n' 2>/dev/null \
      | sort -nr \
      | awk 'NR == 1 {print $2}'
  )"

  if [[ -n "${latest_file}" ]]; then
    printf '%s\n' "${latest_file}"
    return 0
  fi

  latest_file="$(
    find "${APP_DIR}/backups" -maxdepth 1 \( -type f -o -type l \) -name '*-latest.sql.enc' -printf '%T@ %p\n' 2>/dev/null \
      | sort -nr \
      | awk 'NR == 1 {print $2}'
  )"

  if [[ -n "${latest_file}" ]]; then
    printf '%s\n' "${latest_file}"
    return 0
  fi

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
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' basesdedatos 2>/dev/null | awk -F= '/^DB_ENV=/{print $2; exit}' || true
}

default_mode() {
  local mode

  mode="$(running_db_env)"
  if valid_mode "${mode}"; then
    canonical_env_mode "${mode}"
    return 0
  fi

  if [[ -f "${ENTORNO_ENV_FILE}" ]]; then
    mode="$(env_value_from_file "${ENTORNO_ENV_FILE}" ENTORNO_MODE)"
    if valid_mode "${mode}"; then
      canonical_env_mode "${mode}"
      return 0
    fi
  fi

  printf '%s\n' "production"
}

active_mode_from_env() {
  assert_no_legacy_runtime_paths
  ensure_entorno_files
  env_mode_from_file "${ENTORNO_ENV_FILE}"
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

  if ! docker network inspect basesdedatos-internal >/dev/null 2>&1; then
    docker network create --internal basesdedatos-internal >/dev/null
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

  for suffix in "" ".production" ".local"; do
    path="${APP_DIR}/${env_name}${suffix}"
    if [[ -e "${path}" ]]; then
      found+=("${path#${APP_DIR}/}")
    fi
  done

  if (( ${#found[@]} > 0 )); then
    printf 'Rutas legacy fuera de entorno/ detectadas en basesdedatos: %s\n' "${found[*]}" >&2
    printf 'Mueve esos archivos a un backup externo antes de desplegar.\n' >&2
    exit 1
  fi
}

assert_entorno_mode() {
  local expected="$1"
  local actual expected_canonical actual_canonical

  actual="$(env_value_from_file "${ENTORNO_ENV_FILE}" ENTORNO_MODE)"
  expected_canonical="$(canonical_env_mode "${expected}")"
  actual_canonical="$(canonical_env_mode "${actual}" 2>/dev/null || true)"

  if [[ "${actual_canonical}" != "${expected_canonical}" ]]; then
    echo "ENTORNO_MODE=${actual:-<vacio>} en ${ENTORNO_ENV_FILE}; esperado ${expected}." >&2
    exit 1
  fi
}

resolve_env_file() {
  local mode="${1:-production}"
  local env_file="${ENTORNO_ENV_FILE}"
  require_valid_mode "${mode}"
  mode="$(canonical_env_mode "${mode}")"
  assert_no_legacy_runtime_paths
  ensure_entorno_files
  assert_entorno_mode "${mode}"
  validate_db_env_for_mode "${mode}" "${env_file}"
  printf '%s\n' "${env_file}"
  return 0
}

validate_db_env_for_mode() {
  local mode="$1"
  local env_file="$2"
  local db_env data_dir bind_ip

  db_env="$(env_value_from_file "${env_file}" DB_ENV)"
  data_dir="$(env_value_from_file "${env_file}" POSTGRES_DATA_DIR)"
  bind_ip="$(env_value_from_file "${env_file}" POSTGRES_BIND_IP)"

  if [[ -z "${data_dir}" ]]; then
    echo "POSTGRES_DATA_DIR debe estar definido en ${env_file}" >&2
    exit 1
  fi

  case "${mode}" in
    qa)
      if [[ "${db_env}" != "qa" ]]; then
        echo "DB_ENV=${db_env:-<vacio>} no es valido para QA; usa qa." >&2
        exit 1
      fi
      if [[ "${bind_ip:-127.0.0.1}" == "0.0.0.0" ]]; then
        echo "POSTGRES_BIND_IP=${bind_ip} no es valido para QA; no debe exponerse en 0.0.0.0." >&2
        exit 1
      fi
      ;;
    production)
      if [[ "${db_env}" != "production" ]]; then
        echo "DB_ENV=${db_env:-<vacio>} no es valido para production; usa production." >&2
        exit 1
      fi
      ;;
  esac
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

  POSTGRES_DATA_DIR="${POSTGRES_DATA_DIR:-./postgres18_data}"
  DATA_DIR="$(absolute_app_path "${POSTGRES_DATA_DIR}")"
  export POSTGRES_DATA_DIR DATA_DIR
}

create_database_if_missing() {
  local env_file="$1"
  local database_name="$2"
  local owner_role="${3:-}"
  local exists

  if ! safe_identifier "${database_name}"; then
    echo "Nombre de base de datos inseguro: ${database_name}" >&2
    exit 1
  fi

  exists="$(
    compose_cmd "${env_file}" exec -T -e PGPASSWORD="${POSTGRES_PASSWORD}" db \
      psql -h 127.0.0.1 -U "${POSTGRES_USER}" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '${database_name}'"
  )"

  if [[ "${exists}" == "1" ]]; then
    return 0
  fi

  if [[ -n "${owner_role}" ]]; then
    compose_cmd "${env_file}" exec -T -e PGPASSWORD="${POSTGRES_PASSWORD}" db \
      psql -h 127.0.0.1 -U "${POSTGRES_USER}" -d postgres -v ON_ERROR_STOP=1 <<SQL >/dev/null
CREATE DATABASE "${database_name}" OWNER "${owner_role}";
SQL
    return 0
  fi

  compose_cmd "${env_file}" exec -T -e PGPASSWORD="${POSTGRES_PASSWORD}" db \
    psql -h 127.0.0.1 -U "${POSTGRES_USER}" -d postgres -v ON_ERROR_STOP=1 <<SQL >/dev/null
CREATE DATABASE "${database_name}";
SQL
}

ensure_database_role() {
  local env_file="$1"
  local role_name="$2"
  local role_password="$3"
  local role_exists

  if ! safe_identifier "${role_name}"; then
    echo "Nombre de rol inseguro: ${role_name}" >&2
    exit 1
  fi

  role_exists="$(
    compose_cmd "${env_file}" exec -T -e PGPASSWORD="${POSTGRES_PASSWORD}" db \
      psql -h 127.0.0.1 -U "${POSTGRES_USER}" -d postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname = '${role_name}'"
  )"

  if [[ "${role_exists}" == "1" ]]; then
    compose_cmd "${env_file}" exec -T -e PGPASSWORD="${POSTGRES_PASSWORD}" db \
      psql -h 127.0.0.1 -U "${POSTGRES_USER}" -d postgres -v ON_ERROR_STOP=1 -v role_password="${role_password}" <<SQL >/dev/null
ALTER ROLE "${role_name}" WITH LOGIN PASSWORD :'role_password';
SQL
    return 0
  fi

  compose_cmd "${env_file}" exec -T -e PGPASSWORD="${POSTGRES_PASSWORD}" db \
    psql -h 127.0.0.1 -U "${POSTGRES_USER}" -d postgres -v ON_ERROR_STOP=1 -v role_password="${role_password}" <<SQL >/dev/null
CREATE ROLE "${role_name}" WITH LOGIN PASSWORD :'role_password';
SQL
}

grant_database_access() {
  local env_file="$1"
  local database_name="$2"
  local role_name="$3"
  local owner_flag="${4:-true}"

  if ! safe_identifier "${database_name}" || ! safe_identifier "${role_name}"; then
    echo "No se pueden aplicar grants por identificadores inseguros: ${database_name}/${role_name}" >&2
    exit 1
  fi

  compose_cmd "${env_file}" exec -T -e PGPASSWORD="${POSTGRES_PASSWORD}" db \
    psql -h 127.0.0.1 -U "${POSTGRES_USER}" -d postgres -v ON_ERROR_STOP=1 <<SQL >/dev/null
$(if [[ "${owner_flag}" == "true" ]]; then printf 'ALTER DATABASE "%s" OWNER TO "%s";\n' "${database_name}" "${role_name}"; fi)
GRANT CONNECT ON DATABASE "${database_name}" TO "${role_name}";
SQL

  compose_cmd "${env_file}" exec -T -e PGPASSWORD="${POSTGRES_PASSWORD}" db \
    psql -h 127.0.0.1 -U "${POSTGRES_USER}" -d "${database_name}" -v ON_ERROR_STOP=1 <<SQL >/dev/null
CREATE EXTENSION IF NOT EXISTS postgres_fdw;
GRANT USAGE ON FOREIGN DATA WRAPPER postgres_fdw TO "${role_name}";
GRANT USAGE, CREATE ON SCHEMA public TO "${role_name}";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO "${role_name}";
GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA public TO "${role_name}";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO "${role_name}";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO "${role_name}";
SQL
}

sync_module_databases() {
  local env_file="$1"
  local module_key database_name role_source optional_flag role_env_ref db_key user_key password_key owner_flag
  local runtime_env_file declared_database runtime_user runtime_password optional
  local spec
  local -a module_specs=()

  if [[ ! -f "${MODULE_DATABASES_REGISTRY_FILE}" ]]; then
    echo "No existe el registro de bases por modulo: ${MODULE_DATABASES_REGISTRY_FILE}" >&2
    exit 1
  fi

  mapfile -t module_specs < <(module_database_specs)

  for spec in "${module_specs[@]}"; do
    IFS=$'\t' read -r module_key database_name role_source optional_flag role_env_ref db_key user_key password_key owner_flag <<< "${spec}"
    [[ -n "${module_key}" ]] || continue
    optional="${optional_flag:-false}"
    owner_flag="${owner_flag:-true}"
    runtime_env_file=""
    declared_database="${database_name}"
    runtime_user=""
    runtime_password=""

    case "${role_source}" in
      env-file)
        runtime_env_file="$(absolute_app_path "${role_env_ref}")"
        if [[ ! -f "${runtime_env_file}" ]]; then
          if [[ "${optional}" == "true" ]]; then
            echo "Aviso: falta ${runtime_env_file}; se crea ${database_name} sin rol runtime para ${module_key}."
            create_database_if_missing "${env_file}" "${database_name}"
            continue
          fi
          echo "Falta ${runtime_env_file} para sincronizar ${module_key}." >&2
          exit 1
        fi
        declared_database="$(env_value_from_file "${runtime_env_file}" "${db_key}")"
        declared_database="${declared_database:-${database_name}}"
        runtime_user="$(env_value_from_file "${runtime_env_file}" "${user_key}")"
        runtime_password="$(env_value_from_file "${runtime_env_file}" "${password_key}")"
        ;;
      db-env)
        runtime_user="$(env_value_from_file "${env_file}" "${user_key}")"
        runtime_password="$(env_value_from_file "${env_file}" "${password_key}")"
        ;;
      "")
        ;;
      *)
        echo "Fuente de rol no soportada para ${module_key}: ${role_source}" >&2
        exit 1
        ;;
    esac

    if ! safe_identifier "${declared_database}"; then
      echo "Database declarada para ${module_key} no es segura: ${declared_database}" >&2
      exit 1
    fi

    if [[ -n "${runtime_user}" ]] && ! safe_identifier "${runtime_user}"; then
      echo "Rol runtime para ${module_key} no es seguro: ${runtime_user}" >&2
      exit 1
    fi

    if [[ -n "${runtime_user}" && -n "${runtime_password}" ]]; then
      ensure_database_role "${env_file}" "${runtime_user}" "${runtime_password}"
      create_database_if_missing "${env_file}" "${declared_database}" "${runtime_user}"
      grant_database_access "${env_file}" "${declared_database}" "${runtime_user}" "${owner_flag}"
      echo "Sincronizada DB ${declared_database} para ${module_key} con rol ${runtime_user}."
      continue
    fi

    if [[ "${optional}" == "true" ]]; then
      create_database_if_missing "${env_file}" "${declared_database}"
      echo "Sincronizada DB ${declared_database} para ${module_key} sin rol runtime aun."
      continue
    fi

    echo "Faltan credenciales runtime para ${module_key} (${declared_database})." >&2
    exit 1
  done
}

assert_db_mode() {
  local env_file="$1"
  local container_env expected_env

  container_env="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' basesdedatos 2>/dev/null | awk -F= '/^DB_ENV=/{print $2; exit}')"
  expected_env="$(env_value_from_file "${env_file}" DB_ENV)"
  if [[ "${container_env}" != "${expected_env}" ]]; then
    echo "La base de datos quedo en DB_ENV=${container_env:-desconocido}, esperado ${expected_env:-<vacio>}" >&2
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

remove_renamed_compose_container() {
  local container_name="$1"
  local expected_project
  local current_project

  if ! docker ps -a --format '{{.Names}}' | grep -qx "${container_name}"; then
    return 0
  fi

  expected_project="$(basename "${APP_DIR}")"
  current_project="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "${container_name}" 2>/dev/null || true)"
  if [[ -n "${current_project}" && "${current_project}" != "${expected_project}" ]]; then
    echo "Removiendo contenedor ${container_name} del proyecto Compose anterior (${current_project}); los datos permanecen en ${DATA_DIR}."
    docker rm -f "${container_name}" >/dev/null
  fi
}

remove_legacy_db_container() {
  local container_name="next-test-db"

  if docker ps -a --format '{{.Names}}' | grep -qx "${container_name}"; then
    echo "Removiendo contenedor legacy ${container_name}; los datos permanecen en ${DATA_DIR}."
    docker rm -f "${container_name}" >/dev/null
  fi
}

deploy_database() {
  local mode="${1:-production}"
  local env_file

  ensure_prereqs
  mode="$(canonical_env_mode "${mode}")"
  env_file="$(resolve_env_file "${mode}")"
  load_env_file "${env_file}"

  echo "Levantando PostgreSQL (${mode}) usando ${env_file}..."
  remove_legacy_db_container
  remove_renamed_compose_container basesdedatos
  compose_cmd "${env_file}" up -d --force-recreate --remove-orphans db
  wait_for_db "${env_file}"
  assert_db_mode "${env_file}"
  sync_module_databases "${env_file}"
  compose_cmd "${env_file}" ps
  echo "Base de datos (${mode}) lista"
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

  require_valid_mode "${mode}"
  sync_module_databases "${env_file}"
}
