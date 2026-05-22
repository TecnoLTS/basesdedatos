#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

umask 077

MODE="${1:-production}"
ENV_FILE="$(resolve_env_file "${MODE}")"

ensure_prereqs
load_env_file "${ENV_FILE}"

TMP_FILE="${BACKUP_FILE}.tmp"
mkdir -p "$(dirname "${BACKUP_FILE}")"

running_db_env="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' next-test-db 2>/dev/null | awk -F= '/^DB_ENV=/{print $2; exit}' || true)"
if [[ -n "${running_db_env}" && "${running_db_env}" != "${MODE}" ]]; then
  echo "La base principal esta levantada en modo ${running_db_env}, pero solicitaste backup ${MODE}." >&2
  echo "Usa ./scripts/backup-and-stop.sh ${running_db_env} para respaldar esta base, o despliega ${MODE} antes de respaldar ese ambiente." >&2
  exit 1
fi

echo "Levantando PostgreSQL para exportar el cluster..."
compose_cmd "${ENV_FILE}" up -d --remove-orphans db
wait_for_db "${ENV_FILE}"
assert_db_mode "${MODE}"

echo "Generando snapshot completo cifrado en ${BACKUP_FILE}..."
compose_cmd "${ENV_FILE}" exec -T -e PGPASSWORD="${POSTGRES_PASSWORD}" db \
  pg_dumpall -U "${POSTGRES_USER}" --clean --if-exists \
  | normalize_dump_stream | encrypt_backup_stream > "${TMP_FILE}"
mv "${TMP_FILE}" "${BACKUP_FILE}"
chmod 600 "${BACKUP_FILE}"

echo "Apagando servicio de base de datos..."
compose_cmd "${ENV_FILE}" down --remove-orphans

echo "Snapshot listo y servicio detenido"
