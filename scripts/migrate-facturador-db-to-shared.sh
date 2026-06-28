#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

MODE="${1:-qa}"
SOURCE_CONTAINER="${SOURCE_CONTAINER:-billing-postgres}"
FACT_ENV_FILE="${APP_DIR}/../Facturador/entorno/.env"
SHARED_DB_CONTAINER="${SHARED_DB_CONTAINER:-basesdedatos}"

require_valid_mode "${MODE}"
ensure_prereqs

if [[ ! -f "${FACT_ENV_FILE}" ]]; then
  echo "No existe ${FACT_ENV_FILE}; no se puede migrar Facturador." >&2
  exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -qx "${SOURCE_CONTAINER}"; then
  echo "No esta corriendo ${SOURCE_CONTAINER}; no hay origen legacy para migrar." >&2
  exit 1
fi

ENV_FILE="$(resolve_env_file "${MODE}")"
load_env_file "${ENV_FILE}"
compose_cmd "${ENV_FILE}" up -d db >/dev/null
wait_for_db "${ENV_FILE}"
assert_db_mode "${MODE}"
sync_module_databases "${ENV_FILE}"

FACT_DB_NAME="$(env_value_from_file "${FACT_ENV_FILE}" "DB_NAME")"
FACT_DB_USER="$(env_value_from_file "${FACT_ENV_FILE}" "DB_USER")"
FACT_DB_PASSWORD="$(env_value_from_file "${FACT_ENV_FILE}" "DB_PASSWORD")"

if [[ -z "${FACT_DB_NAME}" || -z "${FACT_DB_USER}" || -z "${FACT_DB_PASSWORD}" ]]; then
  echo "Faltan DB_NAME, DB_USER o DB_PASSWORD en ${FACT_ENV_FILE}." >&2
  exit 1
fi

if ! safe_identifier "${FACT_DB_NAME}" || ! safe_identifier "${FACT_DB_USER}"; then
  echo "DB o rol de Facturador no seguros: ${FACT_DB_NAME}/${FACT_DB_USER}" >&2
  exit 1
fi

table_counts() {
  local container_name="$1"

  docker exec "${container_name}" env PGPASSWORD="${FACT_DB_PASSWORD}" \
    psql -h 127.0.0.1 -U "${FACT_DB_USER}" -d "${FACT_DB_NAME}" -At -F '|' -v ON_ERROR_STOP=1 \
      -c "SELECT 'client_branches', COUNT(*) FROM client_branches
          UNION ALL
          SELECT 'clients', COUNT(*) FROM clients
          UNION ALL
          SELECT 'invoice_details', COUNT(*) FROM invoice_details
          UNION ALL
          SELECT 'invoice_headers', COUNT(*) FROM invoice_headers
          ORDER BY 1;"
}

source_counts="$(table_counts "${SOURCE_CONTAINER}")"

echo "Migrando Facturador desde ${SOURCE_CONTAINER}:${FACT_DB_NAME} hacia ${SHARED_DB_CONTAINER}:${FACT_DB_NAME}..."
docker exec "${SOURCE_CONTAINER}" env PGPASSWORD="${FACT_DB_PASSWORD}" \
  pg_dump -h 127.0.0.1 -U "${FACT_DB_USER}" -d "${FACT_DB_NAME}" --clean --if-exists --no-owner --no-privileges \
  | docker exec -i "${SHARED_DB_CONTAINER}" env PGPASSWORD="${FACT_DB_PASSWORD}" \
      psql -h 127.0.0.1 -U "${FACT_DB_USER}" -d "${FACT_DB_NAME}" -v ON_ERROR_STOP=1 >/dev/null

target_counts="$(table_counts "${SHARED_DB_CONTAINER}")"

echo "Conteos origen:"
printf '%s\n' "${source_counts}"
echo "Conteos destino:"
printf '%s\n' "${target_counts}"
echo "Migracion completada. El contenedor legacy ${SOURCE_CONTAINER} queda disponible como rollback hasta que decidas retirarlo."
