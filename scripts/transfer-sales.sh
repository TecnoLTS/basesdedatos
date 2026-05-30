#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'USAGE'
Uso:
  ./scripts/transfer-sales.sh export <ORDER_ID> [ORDER_ID...] [--stage] [--label nombre] [--mode production|development]
  ./scripts/transfer-sales.sh export --latest 2 [--stage] [--label nombre] [--mode production|development]
  ./scripts/transfer-sales.sh restore [git-transfer/sales-*.json.enc] [--yes] [--mode production|development]

Exporta solo ventas seleccionadas y sus dependencias directas:
  - User asociado a la orden
  - Order
  - OrderItem
  - InventoryLotAllocation
  - DiscountAudit asociado a order_id

La restauracion es idempotente: si la orden ya existe en destino, no se vuelve
a insertar ni se vuelve a descontar inventario.
USAGE
}

read_transfer_passphrase() {
  local prompt="$1"
  local confirm="${2:-0}"
  local first second

  if [[ ! -t 0 ]]; then
    echo "Este comando necesita una terminal interactiva para pedir la clave temporal." >&2
    echo "Alternativa: exporta TRANSFER_SALES_PASSPHRASE antes de ejecutarlo." >&2
    exit 1
  fi

  printf '%s: ' "${prompt}" >&2
  read -r -s first
  echo >&2
  if [[ "${#first}" -lt 20 ]]; then
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

safe_label() {
  printf '%s' "$1" | tr -cs '[:alnum:]_.-' '-'
}

validate_order_id() {
  local id="$1"

  if [[ ! "${id}" =~ ^[A-Za-z0-9_.:-]+$ ]]; then
    echo "ORDER_ID invalido: ${id}" >&2
    exit 1
  fi
}

sql_values_for_order_ids() {
  local id
  local first=1

  for id in "$@"; do
    validate_order_id "${id}"
    if [[ "${first}" == "1" ]]; then
      first=0
    else
      printf ','
    fi
    printf "('%s')" "${id}"
  done
}

psql_db() {
  compose_cmd "${ENV_FILE}" exec -T -e PGPASSWORD="${POSTGRES_PASSWORD}" db \
    psql -h 127.0.0.1 -v ON_ERROR_STOP=1 -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" "$@"
}

latest_sales_transfer_backup() {
  find "${APP_DIR}/git-transfer" -maxdepth 1 -type f -name 'sales-*.json.enc' -printf '%T@ %p\n' 2>/dev/null \
    | sort -nr \
    | awk 'NR == 1 {print $2}'
}

COMMAND="${1:-}"
if [[ -z "${COMMAND}" || "${COMMAND}" == "--help" || "${COMMAND}" == "-h" ]]; then
  usage
  exit 0
fi
shift

MODE=""
LABEL="sales"
STAGE=0
ASSUME_YES=0
LATEST_COUNT=""
BACKUP_ARG=""
ORDER_IDS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="${2:-}"
      if [[ -z "${MODE}" ]]; then
        echo "Falta valor para --mode" >&2
        exit 1
      fi
      shift
      ;;
    --label)
      LABEL="${2:-}"
      if [[ -z "${LABEL}" ]]; then
        echo "Falta valor para --label" >&2
        exit 1
      fi
      shift
      ;;
    --stage)
      STAGE=1
      ;;
    --yes|-y)
      ASSUME_YES=1
      ;;
    --latest)
      LATEST_COUNT="${2:-}"
      if [[ ! "${LATEST_COUNT}" =~ ^[1-9][0-9]*$ ]]; then
        echo "Valor invalido para --latest: ${LATEST_COUNT}" >&2
        exit 1
      fi
      shift
      ;;
    *)
      if [[ "${COMMAND}" == "restore" || "${COMMAND}" == "import" ]]; then
        if [[ -z "${BACKUP_ARG}" ]]; then
          BACKUP_ARG="$1"
        else
          echo "Argumento no reconocido: $1" >&2
          usage >&2
          exit 1
        fi
      else
        ORDER_IDS+=("$1")
      fi
      ;;
  esac
  shift
done

if [[ -z "${MODE}" ]]; then
  MODE="$(default_mode)"
fi
require_valid_mode "${MODE}"

ENV_FILE="$(resolve_env_file "${MODE}")"
ensure_prereqs
load_env_file "${ENV_FILE}"

case "${COMMAND}" in
  export)
    if [[ -n "$(running_db_env)" && "$(running_db_env)" != "${MODE}" ]]; then
      echo "El contenedor activo esta en modo $(running_db_env), pero export solicitó ${MODE}." >&2
      exit 1
    fi

    if [[ ! -f "${DATA_DIR}/18/docker/PG_VERSION" ]]; then
      echo "No existe un cluster inicializado para ${MODE} en ${DATA_DIR}" >&2
      exit 1
    fi

    compose_cmd "${ENV_FILE}" up -d --remove-orphans db >/dev/null
    wait_for_db "${ENV_FILE}"
    assert_db_mode "${MODE}"

    if [[ -n "${LATEST_COUNT}" ]]; then
      mapfile -t ORDER_IDS < <(
        psql_db -At -c "SELECT id FROM \"Order\" WHERE lower(COALESCE(status, 'completed')) NOT IN ('canceled', 'cancelled') ORDER BY created_at DESC LIMIT ${LATEST_COUNT};"
      )
    fi

    if [[ "${#ORDER_IDS[@]}" -eq 0 ]]; then
      echo "Debes indicar al menos un ORDER_ID o usar --latest 2." >&2
      usage >&2
      exit 1
    fi

    VALUES_SQL="$(sql_values_for_order_ids "${ORDER_IDS[@]}")"
    MISSING="$(
      psql_db -At -c "WITH requested(order_id) AS (VALUES ${VALUES_SQL}) SELECT order_id FROM requested r WHERE NOT EXISTS (SELECT 1 FROM \"Order\" o WHERE o.id = r.order_id) ORDER BY order_id;"
    )"
    if [[ -n "${MISSING}" ]]; then
      echo "No existen estas ordenes en origen:" >&2
      printf '%s\n' "${MISSING}" >&2
      exit 1
    fi

    echo "Ventas seleccionadas en ${MODE}:"
    psql_db -P pager=off -c "
      WITH requested(order_id) AS (VALUES ${VALUES_SQL})
      SELECT o.id, o.created_at, o.status, o.total, o.user_id, u.email
      FROM requested r
      JOIN \"Order\" o ON o.id = r.order_id
      LEFT JOIN \"User\" u ON u.id = o.user_id
      ORDER BY o.created_at;
    "

    if [[ "${ASSUME_YES}" != "1" && -t 0 ]]; then
      printf '%s' "Escribe EXPORTAR-VENTAS para continuar: "
      read -r typed
      if [[ "${typed}" != "EXPORTAR-VENTAS" ]]; then
        echo "Cancelado."
        exit 1
      fi
    fi

    PASSPHRASE="${TRANSFER_SALES_PASSPHRASE:-${TRANSFER_BACKUP_PASSPHRASE:-}}"
    if [[ -z "${PASSPHRASE}" ]]; then
      PASSPHRASE="$(read_transfer_passphrase "Elige una clave temporal para estas ventas" 1)"
    fi

    TIMESTAMP="$(timestamp_utc)"
    TRANSFER_DIR="${APP_DIR}/git-transfer"
    PACKAGE_BASENAME="sales-${MODE}-$(safe_label "${LABEL}")-${TIMESTAMP}.json.enc"
    BACKUP_PATH="${TRANSFER_DIR}/${PACKAGE_BASENAME}"
    MANIFEST_PATH="${BACKUP_PATH}.manifest"
    mkdir -p "${TRANSFER_DIR}"

    PAYLOAD_JSON="$(
      psql_db -At -c "
        WITH requested(order_id) AS (VALUES ${VALUES_SQL}),
        selected_orders AS (
          SELECT o.*
          FROM \"Order\" o
          JOIN requested r ON r.order_id = o.id
        ),
        selected_items AS (
          SELECT oi.*
          FROM \"OrderItem\" oi
          JOIN selected_orders o ON o.id = oi.order_id
        ),
        selected_allocations AS (
          SELECT a.*
          FROM \"InventoryLotAllocation\" a
          JOIN selected_items oi ON oi.id = a.order_item_id
        ),
        selected_discount_audits AS (
          SELECT d.*
          FROM \"DiscountAudit\" d
          JOIN selected_orders o ON o.id = d.order_id
        ),
        selected_users AS (
          SELECT DISTINCT u.*
          FROM \"User\" u
          JOIN selected_orders o ON o.user_id = u.id
        )
        SELECT jsonb_build_object(
          'kind', 'paramascotas-sales-transfer',
          'version', 1,
          'source_mode', '${MODE}',
          'created_at_utc', '${TIMESTAMP}',
          'order_count', (SELECT COUNT(*) FROM selected_orders),
          'item_count', (SELECT COUNT(*) FROM selected_items),
          'allocation_count', (SELECT COUNT(*) FROM selected_allocations),
          'discount_audit_count', (SELECT COUNT(*) FROM selected_discount_audits),
          'users', COALESCE((SELECT jsonb_agg(to_jsonb(u) ORDER BY u.id) FROM selected_users u), '[]'::jsonb),
          'orders', COALESCE((SELECT jsonb_agg(to_jsonb(o) ORDER BY o.created_at, o.id) FROM selected_orders o), '[]'::jsonb),
          'order_items', COALESCE((SELECT jsonb_agg(to_jsonb(oi) ORDER BY oi.order_id, oi.id) FROM selected_items oi), '[]'::jsonb),
          'inventory_lot_allocations', COALESCE((SELECT jsonb_agg(to_jsonb(a) ORDER BY a.order_item_id, a.id) FROM selected_allocations a), '[]'::jsonb),
          'discount_audits', COALESCE((SELECT jsonb_agg(to_jsonb(d) ORDER BY d.created_at, d.id) FROM selected_discount_audits d), '[]'::jsonb)
        )::text;
      "
    )"

    printf '%s\n' "${PAYLOAD_JSON}" | BACKUP_ENCRYPTION_PASSPHRASE="${PASSPHRASE}" encrypt_backup_stream > "${BACKUP_PATH}.tmp"
    mv "${BACKUP_PATH}.tmp" "${BACKUP_PATH}"
    chmod 600 "${BACKUP_PATH}"
    (
      cd "${TRANSFER_DIR}"
      sha256sum "${PACKAGE_BASENAME}" > "${PACKAGE_BASENAME}.sha256"
      chmod 600 "${PACKAGE_BASENAME}.sha256"
    )
    cat > "${MANIFEST_PATH}" <<EOF
kind=paramascotas-sales-transfer
source_mode=${MODE}
created_at_utc=${TIMESTAMP}
backup_file=${PACKAGE_BASENAME}
checksum_file=${PACKAGE_BASENAME}.sha256
orders=${ORDER_IDS[*]}
restore_script=./scripts/transfer-sales.sh restore
EOF
    chmod 644 "${MANIFEST_PATH}"

    if [[ "${STAGE}" == "1" ]]; then
      git -C "${APP_DIR}" add -f "${BACKUP_PATH}" "${BACKUP_PATH}.sha256" "${MANIFEST_PATH}"
      echo "Paquete agregado al index de Git."
    fi

    echo "Paquete listo:"
    echo "  ${BACKUP_PATH}"
    echo "  ${BACKUP_PATH}.sha256"
    echo "  ${MANIFEST_PATH}"
    echo "Sube estos archivos por Git. La clave temporal no se guarda en el repo."
    ;;
  restore|import)
    if [[ -z "${BACKUP_ARG}" ]]; then
      BACKUP_ARG="$(latest_sales_transfer_backup)"
      if [[ -z "${BACKUP_ARG}" ]]; then
        echo "No encontre paquetes de ventas en git-transfer/. Indica la ruta del .json.enc." >&2
        exit 1
      fi
      echo "Paquete detectado: ${BACKUP_ARG#${APP_DIR}/}"
    fi

    BACKUP_PATH="$(absolute_app_path "${BACKUP_ARG}")"
    if [[ ! -f "${BACKUP_PATH}" ]]; then
      echo "No existe el paquete ${BACKUP_PATH}" >&2
      exit 1
    fi

    if [[ -f "${BACKUP_PATH}.sha256" ]]; then
      (
        cd "$(dirname "${BACKUP_PATH}")"
        sha256sum -c "$(basename "${BACKUP_PATH}").sha256"
      )
    else
      echo "Advertencia: no existe checksum ${BACKUP_PATH}.sha256" >&2
    fi

    PASSPHRASE="${TRANSFER_SALES_PASSPHRASE:-${TRANSFER_BACKUP_PASSPHRASE:-}}"
    if [[ -z "${PASSPHRASE}" ]]; then
      PASSPHRASE="$(read_transfer_passphrase "Ingresa la misma clave temporal usada en origen" 0)"
    fi

    PAYLOAD_JSON="$(BACKUP_ENCRYPTION_PASSPHRASE="${PASSPHRASE}" decrypt_backup_stream < "${BACKUP_PATH}")"
    PAYLOAD_B64="$(printf '%s' "${PAYLOAD_JSON}" | base64 | tr -d '\n')"

    if [[ "${ASSUME_YES}" != "1" && -t 0 ]]; then
      echo "Se restauraran ventas en ${MODE}. El proceso no duplica ordenes existentes."
      printf '%s' "Escribe RESTAURAR-VENTAS para continuar: "
      read -r typed
      if [[ "${typed}" != "RESTAURAR-VENTAS" ]]; then
        echo "Cancelado."
        exit 1
      fi
    fi

    compose_cmd "${ENV_FILE}" up -d --remove-orphans db >/dev/null
    wait_for_db "${ENV_FILE}"
    assert_db_mode "${MODE}"

    {
      cat <<'SQL'
\set ON_ERROR_STOP on
BEGIN;
CREATE TEMP TABLE sales_transfer_payload_raw(encoded_payload text) ON COMMIT DROP;
COPY sales_transfer_payload_raw(encoded_payload) FROM STDIN;
SQL
      printf '%s\n' "${PAYLOAD_B64}"
      cat <<'SQL'
\.

CREATE TEMP TABLE sales_transfer_payload ON COMMIT DROP AS
SELECT convert_from(decode(encoded_payload, 'base64'), 'UTF8')::jsonb AS payload
FROM sales_transfer_payload_raw;

DO $$
DECLARE
  payload_kind text;
BEGIN
  SELECT payload->>'kind' INTO payload_kind FROM sales_transfer_payload LIMIT 1;
  IF payload_kind IS DISTINCT FROM 'paramascotas-sales-transfer' THEN
    RAISE EXCEPTION 'Paquete invalido: %', COALESCE(payload_kind, '<null>');
  END IF;
END $$;

CREATE TEMP TABLE transfer_users AS
SELECT * FROM jsonb_populate_recordset(
  NULL::"User",
  (SELECT payload->'users' FROM sales_transfer_payload LIMIT 1)
);

CREATE TEMP TABLE transfer_orders AS
SELECT * FROM jsonb_populate_recordset(
  NULL::"Order",
  (SELECT payload->'orders' FROM sales_transfer_payload LIMIT 1)
);

CREATE TEMP TABLE transfer_order_items AS
SELECT * FROM jsonb_populate_recordset(
  NULL::"OrderItem",
  (SELECT payload->'order_items' FROM sales_transfer_payload LIMIT 1)
);

CREATE TEMP TABLE transfer_allocations AS
SELECT * FROM jsonb_populate_recordset(
  NULL::"InventoryLotAllocation",
  (SELECT payload->'inventory_lot_allocations' FROM sales_transfer_payload LIMIT 1)
);

CREATE TEMP TABLE transfer_discount_audits AS
SELECT * FROM jsonb_populate_recordset(
  NULL::"DiscountAudit",
  (SELECT payload->'discount_audits' FROM sales_transfer_payload LIMIT 1)
);

CREATE TEMP TABLE transfer_new_order_ids AS
SELECT t.id
FROM transfer_orders t
WHERE NOT EXISTS (SELECT 1 FROM "Order" o WHERE o.id = t.id);

DO $$
DECLARE
  missing_products text;
  missing_lots text;
  insufficient_lots text;
  missing_users text;
BEGIN
  SELECT string_agg(DISTINCT ti.product_id, ', ' ORDER BY ti.product_id)
  INTO missing_products
  FROM transfer_order_items ti
  JOIN transfer_new_order_ids n ON n.id = ti.order_id
  LEFT JOIN "Product" p ON p.id = ti.product_id
  WHERE p.id IS NULL;

  IF missing_products IS NOT NULL THEN
    RAISE EXCEPTION 'Faltan productos en destino: %', missing_products;
  END IF;

  SELECT string_agg(DISTINCT ta.lot_id, ', ' ORDER BY ta.lot_id)
  INTO missing_lots
  FROM transfer_allocations ta
  JOIN transfer_order_items ti ON ti.id = ta.order_item_id
  JOIN transfer_new_order_ids n ON n.id = ti.order_id
  LEFT JOIN "InventoryLot" l ON l.id = ta.lot_id
  WHERE l.id IS NULL;

  IF missing_lots IS NOT NULL THEN
    RAISE EXCEPTION 'Faltan lotes en destino: %', missing_lots;
  END IF;

  SELECT string_agg(checks.lot_id || ' disponible=' || checks.remaining_quantity || ' requerido=' || checks.required_quantity, '; ')
  INTO insufficient_lots
  FROM (
    SELECT ta.lot_id, l.remaining_quantity, SUM(ta.quantity)::int AS required_quantity
    FROM transfer_allocations ta
    JOIN transfer_order_items ti ON ti.id = ta.order_item_id
    JOIN transfer_new_order_ids n ON n.id = ti.order_id
    JOIN "InventoryLot" l ON l.id = ta.lot_id
    GROUP BY ta.lot_id, l.remaining_quantity
    HAVING l.remaining_quantity < SUM(ta.quantity)
  ) checks;

  IF insufficient_lots IS NOT NULL THEN
    RAISE EXCEPTION 'Stock insuficiente en destino: %', insufficient_lots;
  END IF;
END $$;

INSERT INTO "User"
SELECT u.*
FROM transfer_users u
WHERE EXISTS (
  SELECT 1
  FROM transfer_orders o
  JOIN transfer_new_order_ids n ON n.id = o.id
  WHERE o.user_id = u.id
)
ON CONFLICT (id) DO NOTHING;

DO $$
DECLARE
  missing_users text;
BEGIN
  SELECT string_agg(DISTINCT o.user_id, ', ' ORDER BY o.user_id)
  INTO missing_users
  FROM transfer_orders o
  JOIN transfer_new_order_ids n ON n.id = o.id
  LEFT JOIN "User" u ON u.id = o.user_id
  WHERE o.user_id IS NOT NULL AND u.id IS NULL;

  IF missing_users IS NOT NULL THEN
    RAISE EXCEPTION 'Faltan usuarios en destino o hay conflicto de email: %', missing_users;
  END IF;
END $$;

INSERT INTO "Order"
SELECT o.*
FROM transfer_orders o
JOIN transfer_new_order_ids n ON n.id = o.id
ON CONFLICT (id) DO NOTHING;

CREATE TEMP TABLE transfer_new_order_items AS
SELECT ti.*
FROM transfer_order_items ti
JOIN transfer_new_order_ids n ON n.id = ti.order_id;

INSERT INTO "OrderItem"
SELECT ti.*
FROM transfer_new_order_items ti
ON CONFLICT (id) DO NOTHING;

CREATE TEMP TABLE transfer_new_allocations AS
SELECT ta.*
FROM transfer_allocations ta
JOIN transfer_new_order_items ti ON ti.id = ta.order_item_id
WHERE NOT EXISTS (
  SELECT 1 FROM "InventoryLotAllocation" existing WHERE existing.id = ta.id
);

WITH allocation_totals AS (
  SELECT lot_id, SUM(quantity)::int AS quantity
  FROM transfer_new_allocations
  GROUP BY lot_id
)
UPDATE "InventoryLot" l
SET remaining_quantity = l.remaining_quantity - allocation_totals.quantity,
    updated_at = NOW()
FROM allocation_totals
WHERE l.id = allocation_totals.lot_id;

INSERT INTO "InventoryLotAllocation"
SELECT ta.*
FROM transfer_new_allocations ta
ON CONFLICT (id) DO NOTHING;

INSERT INTO "DiscountAudit"
SELECT d.*
FROM transfer_discount_audits d
JOIN transfer_new_order_ids n ON n.id = d.order_id
ON CONFLICT (id) DO NOTHING;

WITH applied_discounts AS (
  SELECT discount_code_id, COUNT(*)::int AS used_count
  FROM transfer_discount_audits d
  JOIN transfer_new_order_ids n ON n.id = d.order_id
  WHERE d.discount_code_id IS NOT NULL AND d.action = 'order_applied'
  GROUP BY discount_code_id
)
UPDATE "DiscountCode" dc
SET used_count = dc.used_count + applied_discounts.used_count,
    updated_at = NOW()
FROM applied_discounts
WHERE dc.id = applied_discounts.discount_code_id;

WITH item_totals AS (
  SELECT product_id, SUM(quantity)::int AS quantity
  FROM transfer_new_order_items
  GROUP BY product_id
),
lot_totals AS (
  SELECT product_id, SUM(remaining_quantity)::int AS quantity
  FROM "InventoryLot"
  WHERE product_id IN (SELECT product_id FROM item_totals)
  GROUP BY product_id
)
UPDATE "Product" p
SET sold = p.sold + item_totals.quantity,
    quantity = CASE
      WHEN EXISTS (SELECT 1 FROM "InventoryLot" l WHERE l.product_id = p.id)
        THEN COALESCE(lot_totals.quantity, 0)
      ELSE p.quantity - item_totals.quantity
    END,
    updated_at = NOW()
FROM item_totals
LEFT JOIN lot_totals ON lot_totals.product_id = item_totals.product_id
WHERE p.id = item_totals.product_id;

SELECT 'orders_in_package' AS metric, COUNT(*)::text AS value FROM transfer_orders
UNION ALL SELECT 'orders_imported', COUNT(*)::text FROM transfer_new_order_ids
UNION ALL SELECT 'items_imported', COUNT(*)::text FROM transfer_new_order_items
UNION ALL SELECT 'allocations_imported', COUNT(*)::text FROM transfer_new_allocations
ORDER BY metric;

COMMIT;
SQL
    } | psql_db -P pager=off
    ;;
  *)
    echo "Comando no reconocido: ${COMMAND}" >&2
    usage >&2
    exit 1
    ;;
esac
