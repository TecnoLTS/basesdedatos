#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DB_CONTAINER="${DB_CONTAINER:-basesdedatos}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="${ROOT_DIR}/basesdedatos/backups/regeneracion-modular-${STAMP}"
ACTIVE_DATABASES=(dashboard ecommerce facturacion)

mkdir -p "${BACKUP_DIR}"

run_psql() {
  local database="$1"
  docker exec -i "${DB_CONTAINER}" sh -lc 'PGPASSWORD="$POSTGRES_PASSWORD" psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$1"' sh "${database}"
}

run_pg_dump() {
  local database="$1"
  docker exec "${DB_CONTAINER}" sh -lc 'PGPASSWORD="$POSTGRES_PASSWORD" pg_dump -U "$POSTGRES_USER" -Fc "$1"' sh "${database}"
}

database_exists() {
  local database="$1"
  docker exec -e TARGET_DB="${database}" "${DB_CONTAINER}" sh -lc 'PGPASSWORD="$POSTGRES_PASSWORD" psql -U "$POSTGRES_USER" -d postgres -Atc "SELECT 1 FROM pg_database WHERE datname = '\''${TARGET_DB}'\'' LIMIT 1"' | grep -qx '1'
}

echo "[modular-db] backup_dir=${BACKUP_DIR}"
for database in "${ACTIVE_DATABASES[@]}"; do
  if database_exists "${database}"; then
    echo "[modular-db] backing up ${database}"
    run_pg_dump "${database}" > "${BACKUP_DIR}/${database}.dump"
  else
    echo "[modular-db] database ${database} does not exist; backup skipped"
  fi
done

echo "[modular-db] preparing ecommerce ownership"
run_psql ecommerce <<'SQL'
BEGIN;

CREATE TABLE IF NOT EXISTS "Customer" (
    id text PRIMARY KEY,
    tenant_id text,
    email text NOT NULL,
    name text,
    password text NOT NULL,
    created_at timestamp(3) without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp(3) without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    email_verified boolean DEFAULT false NOT NULL,
    verification_token text,
    role text DEFAULT 'customer' NOT NULL,
    addresses jsonb,
    profile jsonb,
    document_type text,
    document_number text,
    business_name text,
    otp_code text,
    otp_expires_at timestamp,
    otp_attempts integer,
    failed_login_attempts integer,
    login_locked_until timestamp,
    last_login_at timestamp,
    active_token_id text
);

CREATE TABLE IF NOT EXISTS "CustomerAuthSecurityEvent" (
    id text PRIMARY KEY,
    tenant_id text NOT NULL,
    user_id text,
    email text,
    event_type text NOT NULL,
    status text DEFAULT 'info' NOT NULL,
    ip_address text,
    user_agent text,
    metadata jsonb DEFAULT '{}'::jsonb,
    created_at timestamp without time zone DEFAULT NOW() NOT NULL
);

CREATE TABLE IF NOT EXISTS "CustomerPasswordResetToken" (
    id text PRIMARY KEY,
    tenant_id text NOT NULL,
    user_id text NOT NULL,
    token_hash text NOT NULL,
    expires_at timestamp without time zone NOT NULL,
    used_at timestamp without time zone,
    request_ip text,
    request_user_agent text,
    used_ip text,
    used_user_agent text,
    created_at timestamp without time zone DEFAULT NOW() NOT NULL,
    updated_at timestamp without time zone DEFAULT NOW() NOT NULL
);

ALTER TABLE "Order" ADD COLUMN IF NOT EXISTS customer_id text;
ALTER TABLE "ProductReview" ADD COLUMN IF NOT EXISTS customer_id text;

DO $$
BEGIN
    IF to_regclass('public."User"') IS NOT NULL THEN
        INSERT INTO "Customer" (
            id,
            tenant_id,
            email,
            name,
            password,
            created_at,
            updated_at,
            email_verified,
            verification_token,
            role,
            addresses,
            profile,
            document_type,
            document_number,
            business_name,
            otp_code,
            otp_expires_at,
            otp_attempts,
            failed_login_attempts,
            login_locked_until,
            last_login_at,
            active_token_id
        )
        SELECT
            id,
            tenant_id,
            email,
            name,
            password,
            created_at,
            updated_at,
            email_verified,
            verification_token,
            'customer',
            addresses,
            COALESCE(profile, '{}'::jsonb) || jsonb_build_object('identityType', 'customer', 'roleIds', jsonb_build_array('customer')),
            document_type,
            document_number,
            business_name,
            otp_code,
            otp_expires_at,
            otp_attempts,
            failed_login_attempts,
            login_locked_until,
            last_login_at,
            active_token_id
        FROM "User"
        WHERE COALESCE(
            NULLIF(LOWER(TRIM(profile->>'identityType')), ''),
            NULLIF(LOWER(TRIM(profile->>'identity_type')), ''),
            CASE
                WHEN LOWER(COALESCE(role, 'customer')) = 'admin' THEN 'tenant_staff'
                WHEN LOWER(COALESCE(role, 'customer')) = 'service' THEN 'service'
                ELSE 'customer'
            END
        ) = 'customer'
        ON CONFLICT (id) DO UPDATE SET
            tenant_id = EXCLUDED.tenant_id,
            email = EXCLUDED.email,
            name = EXCLUDED.name,
            password = EXCLUDED.password,
            updated_at = GREATEST("Customer".updated_at, EXCLUDED.updated_at),
            email_verified = EXCLUDED.email_verified,
            verification_token = EXCLUDED.verification_token,
            role = 'customer',
            addresses = EXCLUDED.addresses,
            profile = EXCLUDED.profile,
            document_type = EXCLUDED.document_type,
            document_number = EXCLUDED.document_number,
            business_name = EXCLUDED.business_name,
            otp_code = EXCLUDED.otp_code,
            otp_expires_at = EXCLUDED.otp_expires_at,
            otp_attempts = EXCLUDED.otp_attempts,
            failed_login_attempts = EXCLUDED.failed_login_attempts,
            login_locked_until = EXCLUDED.login_locked_until,
            last_login_at = EXCLUDED.last_login_at,
            active_token_id = EXCLUDED.active_token_id;
    END IF;
END $$;

DO $$
BEGIN
    IF to_regclass('public."AuthSecurityEvent"') IS NOT NULL THEN
        INSERT INTO "CustomerAuthSecurityEvent" (
            id,
            tenant_id,
            user_id,
            email,
            event_type,
            status,
            ip_address,
            user_agent,
            metadata,
            created_at
        )
        SELECT
            ase.id,
            ase.tenant_id,
            ase.user_id,
            ase.email,
            ase.event_type,
            ase.status,
            ase.ip_address,
            ase.user_agent,
            ase.metadata,
            ase.created_at
        FROM "AuthSecurityEvent" ase
        JOIN "Customer" c ON c.id = ase.user_id AND c.tenant_id = ase.tenant_id
        ON CONFLICT (id) DO NOTHING;
    END IF;
END $$;

DO $$
BEGIN
    IF to_regclass('public."PasswordResetToken"') IS NOT NULL THEN
        INSERT INTO "CustomerPasswordResetToken" (
            id,
            tenant_id,
            user_id,
            token_hash,
            expires_at,
            used_at,
            request_ip,
            request_user_agent,
            used_ip,
            used_user_agent,
            created_at,
            updated_at
        )
        SELECT
            prt.id,
            prt.tenant_id,
            prt.user_id,
            prt.token_hash,
            prt.expires_at,
            prt.used_at,
            prt.request_ip,
            prt.request_user_agent,
            prt.used_ip,
            prt.used_user_agent,
            prt.created_at,
            prt.updated_at
        FROM "PasswordResetToken" prt
        JOIN "Customer" c ON c.id = prt.user_id AND c.tenant_id = prt.tenant_id
        ON CONFLICT (id) DO NOTHING;
    END IF;
END $$;

UPDATE "Order"
SET customer_id = COALESCE(customer_id, user_id)
WHERE customer_id IS NULL AND user_id IS NOT NULL;

UPDATE "ProductReview"
SET customer_id = COALESCE(customer_id, user_id)
WHERE customer_id IS NULL AND user_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS "Customer_tenant_email_uidx" ON "Customer" (tenant_id, email);
CREATE INDEX IF NOT EXISTS "Customer_tenant_document_idx" ON "Customer" (tenant_id, document_number);
CREATE INDEX IF NOT EXISTS "Customer_tenant_created_idx" ON "Customer" (tenant_id, created_at DESC);
CREATE INDEX IF NOT EXISTS "CustomerAuthSecurityEvent_tenant_created_idx" ON "CustomerAuthSecurityEvent" (tenant_id, created_at DESC);
CREATE INDEX IF NOT EXISTS "CustomerAuthSecurityEvent_tenant_user_idx" ON "CustomerAuthSecurityEvent" (tenant_id, user_id, created_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS "CustomerPasswordResetToken_tenant_hash_uidx" ON "CustomerPasswordResetToken" (tenant_id, token_hash);
CREATE INDEX IF NOT EXISTS "CustomerPasswordResetToken_tenant_user_idx" ON "CustomerPasswordResetToken" (tenant_id, user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS "Order_tenant_customer_idx" ON "Order" (tenant_id, customer_id);
CREATE INDEX IF NOT EXISTS "ProductReview_tenant_customer_idx" ON "ProductReview" (tenant_id, customer_id, created_at DESC);

DO $$
DECLARE
    rel record;
BEGIN
    FOR rel IN
        SELECT c.relname, c.relkind
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
          AND c.relname IN ('User', 'AuthSecurityEvent', 'PasswordResetToken')
    LOOP
        IF rel.relkind = 'f' THEN
            EXECUTE format('DROP FOREIGN TABLE IF EXISTS public.%I CASCADE', rel.relname);
        ELSIF rel.relkind = 'v' THEN
            EXECUTE format('DROP VIEW IF EXISTS public.%I CASCADE', rel.relname);
        ELSE
            EXECUTE format('DROP TABLE IF EXISTS public.%I CASCADE', rel.relname);
        END IF;
    END LOOP;
END $$;

COMMIT;
SQL

echo "[modular-db] preparing dashboard ownership"
run_psql dashboard <<'SQL'
BEGIN;

CREATE TEMP TABLE _customer_users_to_move ON COMMIT DROP AS
SELECT id, tenant_id
FROM "User"
WHERE COALESCE(
    NULLIF(LOWER(TRIM(profile->>'identityType')), ''),
    NULLIF(LOWER(TRIM(profile->>'identity_type')), ''),
    CASE
        WHEN LOWER(COALESCE(role, 'customer')) = 'admin' THEN 'tenant_staff'
        WHEN LOWER(COALESCE(role, 'customer')) = 'service' THEN 'service'
        ELSE 'customer'
    END
) = 'customer';

DELETE FROM tenant_user_roles tur
USING _customer_users_to_move moved
WHERE tur.tenant_id = moved.tenant_id
  AND tur.user_id = moved.id;

DELETE FROM tenant_memberships tm
USING _customer_users_to_move moved
WHERE tm.tenant_id = moved.tenant_id
  AND tm.user_id = moved.id;

DELETE FROM tenant_memberships
WHERE identity_type = 'customer';

DELETE FROM "PasswordResetToken" prt
USING _customer_users_to_move moved
WHERE prt.tenant_id = moved.tenant_id
  AND prt.user_id = moved.id;

DELETE FROM "AuthSecurityEvent" ase
USING _customer_users_to_move moved
WHERE ase.tenant_id = moved.tenant_id
  AND ase.user_id = moved.id;

DELETE FROM "User" u
USING _customer_users_to_move moved
WHERE u.tenant_id = moved.tenant_id
  AND u.id = moved.id;

COMMIT;
SQL

echo "[modular-db] preparing billing fiscal customers"
run_psql facturacion <<'SQL'
BEGIN;

CREATE TABLE IF NOT EXISTS billing_customers (
    id bigserial PRIMARY KEY,
    tenant_id text NOT NULL DEFAULT 'paramascotasec',
    identification text NOT NULL,
    name text NOT NULL,
    email text,
    address text,
    source text NOT NULL DEFAULT 'invoice_headers',
    first_seen_at timestamp with time zone DEFAULT NOW() NOT NULL,
    last_seen_at timestamp with time zone DEFAULT NOW() NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT NOW() NOT NULL,
    updated_at timestamp with time zone DEFAULT NOW() NOT NULL,
    UNIQUE (tenant_id, identification)
);

ALTER TABLE invoice_headers ADD COLUMN IF NOT EXISTS billing_customer_id bigint;

WITH normalized AS (
    SELECT DISTINCT ON (TRIM(customer_identification))
        'paramascotasec'::text AS tenant_id,
        TRIM(customer_identification) AS identification,
        COALESCE(NULLIF(TRIM(customer_name), ''), 'Consumidor final') AS name,
        NULLIF(TRIM(customer_email), '') AS email,
        NULLIF(TRIM(customer_address), '') AS address,
        MIN(created_at) OVER (PARTITION BY TRIM(customer_identification)) AS first_seen_at,
        MAX(updated_at) OVER (PARTITION BY TRIM(customer_identification)) AS last_seen_at
    FROM invoice_headers
    WHERE NULLIF(TRIM(customer_identification), '') IS NOT NULL
    ORDER BY TRIM(customer_identification), updated_at DESC NULLS LAST, created_at DESC NULLS LAST
)
INSERT INTO billing_customers (
    tenant_id,
    identification,
    name,
    email,
    address,
    first_seen_at,
    last_seen_at,
    metadata,
    created_at,
    updated_at
)
SELECT
    tenant_id,
    identification,
    name,
    email,
    address,
    COALESCE(first_seen_at, NOW()),
    COALESCE(last_seen_at, NOW()),
    jsonb_build_object('migratedFrom', 'invoice_headers'),
    NOW(),
    NOW()
FROM normalized
ON CONFLICT (tenant_id, identification) DO UPDATE SET
    name = EXCLUDED.name,
    email = COALESCE(EXCLUDED.email, billing_customers.email),
    address = COALESCE(EXCLUDED.address, billing_customers.address),
    first_seen_at = LEAST(billing_customers.first_seen_at, EXCLUDED.first_seen_at),
    last_seen_at = GREATEST(billing_customers.last_seen_at, EXCLUDED.last_seen_at),
    updated_at = NOW();

UPDATE invoice_headers ih
SET billing_customer_id = bc.id
FROM billing_customers bc
WHERE bc.tenant_id = 'paramascotasec'
  AND bc.identification = TRIM(ih.customer_identification)
  AND ih.billing_customer_id IS DISTINCT FROM bc.id;

CREATE INDEX IF NOT EXISTS billing_customers_tenant_name_idx ON billing_customers (tenant_id, name);
CREATE INDEX IF NOT EXISTS invoice_headers_billing_customer_idx ON invoice_headers (billing_customer_id);

COMMIT;
SQL

echo "[modular-db] counts"
for database in "${ACTIVE_DATABASES[@]}"; do
  run_psql "${database}" <<'SQL'
SELECT current_database() AS database_name;
SQL
done

echo "[modular-db] done"
