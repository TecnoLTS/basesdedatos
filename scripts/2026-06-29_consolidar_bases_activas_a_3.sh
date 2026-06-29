#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${ENV_FILE:-${BASE_DIR}/entorno/.env}"
DB_CONTAINER="${DB_CONTAINER:-basesdedatos}"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "No existe ENV_FILE=${ENV_FILE}" >&2
  exit 1
fi

set -a
source "${ENV_FILE}"
set +a

ADMIN_USER="${POSTGRES_USER:-postgres}"
ADMIN_PASSWORD="${POSTGRES_PASSWORD:?Falta POSTGRES_PASSWORD en ${ENV_FILE}}"
BACKUP_DIR="${BACKUP_DIR:-${BASE_DIR}/backups/consolidacion-3-bases-$(date -u +%Y%m%dT%H%M%SZ)}"

mkdir -p "${BACKUP_DIR}"

psql_exec() {
  local database="$1"
  shift
  docker exec -i -e PGPASSWORD="${ADMIN_PASSWORD}" "${DB_CONTAINER}" \
    psql -h 127.0.0.1 -v ON_ERROR_STOP=1 -U "${ADMIN_USER}" -d "${database}" "$@"
}

psql_at() {
  local database="$1"
  local sql="$2"
  docker exec -e PGPASSWORD="${ADMIN_PASSWORD}" "${DB_CONTAINER}" \
    psql -h 127.0.0.1 -v ON_ERROR_STOP=1 -U "${ADMIN_USER}" -d "${database}" -Atc "${sql}"
}

database_exists() {
  [[ "$(psql_at postgres "SELECT 1 FROM pg_database WHERE datname = '$1'")" == "1" ]]
}

table_exists() {
  local database="$1"
  local table="$2"
  local table_ref="public.\"${table}\""
  [[ "$(psql_at "${database}" "SELECT to_regclass('${table_ref}') IS NOT NULL")" == "t" ]]
}

relation_kind() {
  local database="$1"
  local table="$2"
  psql_at "${database}" "
SELECT COALESCE((
  SELECT c.relkind::text
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relname = '${table}'
  LIMIT 1
), '')"
}

ensure_local_target_table() {
  local source="$1"
  local target="$2"
  local table="$3"
  local table_ref="public.\"${table}\""
  local kind
  kind="$(relation_kind "${target}" "${table}")"
  if [[ "${kind}" == "r" || "${kind}" == "p" ]]; then
    return
  fi
  if [[ "${kind}" == "f" ]]; then
    psql_exec "${target}" -c "DROP FOREIGN TABLE IF EXISTS ${table_ref} CASCADE;" >/dev/null
  fi
  docker exec -e PGPASSWORD="${ADMIN_PASSWORD}" "${DB_CONTAINER}" \
    pg_dump -h 127.0.0.1 -U "${ADMIN_USER}" -d "${source}" \
      --schema-only --table="${table_ref}" \
    | docker exec -i -e PGPASSWORD="${ADMIN_PASSWORD}" "${DB_CONTAINER}" \
        psql -h 127.0.0.1 -v ON_ERROR_STOP=1 -U "${ADMIN_USER}" -d "${target}" >/dev/null
}

terminate_database() {
  local database="$1"
  psql_exec postgres >/dev/null <<SQL
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname = '${database}'
  AND pid <> pg_backend_pid();
SQL
}

backup_database() {
  local database="$1"
  if ! database_exists "${database}"; then
    return
  fi
  docker exec -e PGPASSWORD="${ADMIN_PASSWORD}" "${DB_CONTAINER}" \
    pg_dump -h 127.0.0.1 -U "${ADMIN_USER}" -Fc -d "${database}" \
    > "${BACKUP_DIR}/${database}.dump"
}

rename_if_needed() {
  local source="$1"
  local target="$2"
  if database_exists "${target}"; then
    return
  fi
  if ! database_exists "${source}"; then
    return
  fi
  terminate_database "${source}"
  psql_exec postgres -c "ALTER DATABASE \"${source}\" RENAME TO \"${target}\";" >/dev/null
}

ensure_database() {
  local database="$1"
  if database_exists "${database}"; then
    return
  fi
  psql_exec postgres -c "CREATE DATABASE \"${database}\" OWNER \"${ADMIN_USER}\";" >/dev/null
}

copy_tables() {
  local source="$1"
  local target="$2"
  shift 2
  if [[ "${source}" == "${target}" ]] || ! database_exists "${source}" || ! database_exists "${target}"; then
    return
  fi

  for table in "$@"; do
    if ! table_exists "${source}" "${table}"; then
      continue
    fi
    local table_ref="public.\"${table}\""
    ensure_local_target_table "${source}" "${target}" "${table}"
    echo "Copiando ${source}.${table} -> ${target}.${table}"
    psql_exec "${target}" -c "ALTER TABLE ${table_ref} DISABLE TRIGGER ALL;" >/dev/null || true
    docker exec -e PGPASSWORD="${ADMIN_PASSWORD}" "${DB_CONTAINER}" \
      pg_dump -h 127.0.0.1 -U "${ADMIN_USER}" -d "${source}" \
        --data-only --inserts --column-inserts --on-conflict-do-nothing \
        --table="${table_ref}" \
      | docker exec -i -e PGPASSWORD="${ADMIN_PASSWORD}" "${DB_CONTAINER}" \
          psql -h 127.0.0.1 -v ON_ERROR_STOP=1 -U "${ADMIN_USER}" -d "${target}" >/dev/null
    psql_exec "${target}" -c "ALTER TABLE ${table_ref} ENABLE TRIGGER ALL;" >/dev/null || true
  done
}

drop_database_if_extra() {
  local database="$1"
  case "${database}" in
    dashboard|ecommerce|facturacion|postgres)
      return
      ;;
  esac
  if ! database_exists "${database}"; then
    return
  fi
  terminate_database "${database}"
  psql_exec postgres -c "DROP DATABASE \"${database}\";" >/dev/null
}

IDENTITY_TABLES=(
  Tenant User tenant_module_entitlements tenant_memberships tenant_roles
  tenant_user_roles AuthSecurityEvent PasswordResetToken Setting
)
CATALOG_TABLES=(
  Product Image Variation PurchaseInvoice PurchaseInvoiceItem InventoryLot
  InventoryLotAllocation ProductReferenceCatalog ProductReview
)
COMMERCE_TABLES=(
  Order OrderItem Quotation DiscountCode DiscountAudit PosShift PosMovement
)
REPORTING_TABLES=(
  FinancialPeriod FinancialAdjustment BusinessExpenseRecurrence BusinessExpense
  BusinessExpensePayment
)
MAILER_TABLES=(
  ContactMessage EmailOutbox EmailDeliveryLog
)
BILLING_TABLES=(
  clients client_branches branch_sequences invoice_headers invoice_details
  invoice_retry_settings api_keys billing_domain_events
)

echo "Respaldando bases existentes en ${BACKUP_DIR}"
while IFS= read -r database; do
  backup_database "${database}"
done < <(psql_at postgres "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname")

rename_if_needed paramascotasec ecommerce
rename_if_needed billing_service facturacion
rename_if_needed identity_platform dashboard
rename_if_needed identidad dashboard

ensure_database ecommerce
ensure_database dashboard
ensure_database facturacion

copy_tables paramascotasec ecommerce "${CATALOG_TABLES[@]}" "${COMMERCE_TABLES[@]}" "${REPORTING_TABLES[@]}"
copy_tables catalog_inventory ecommerce "${CATALOG_TABLES[@]}"
copy_tables catalogo_inventario ecommerce "${CATALOG_TABLES[@]}"
copy_tables commerce_orders ecommerce "${COMMERCE_TABLES[@]}"
copy_tables ventas_pedidos ecommerce "${COMMERCE_TABLES[@]}"
copy_tables reporting_finance ecommerce "${REPORTING_TABLES[@]}"
copy_tables reportes_finanzas ecommerce "${REPORTING_TABLES[@]}"

copy_tables identity_platform dashboard "${IDENTITY_TABLES[@]}"
copy_tables identidad dashboard "${IDENTITY_TABLES[@]}"
copy_tables mailer_service dashboard "${MAILER_TABLES[@]}"
copy_tables correos dashboard "${MAILER_TABLES[@]}"

copy_tables billing_service facturacion "${BILLING_TABLES[@]}"

for database in \
  paramascotasec identity_platform identidad catalog_inventory catalogo_inventario \
  commerce_orders ventas_pedidos reporting_finance reportes_finanzas \
  mailer_service correos billing_service tecnolts
do
  drop_database_if_extra "${database}"
done

echo "Bases finales:"
psql_at postgres "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname"
