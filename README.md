# `basesdedatos`

Unidad de despliegue del PostgreSQL compartido del workspace.

## Resumen

- PostgreSQL `18.x`
- Contenedor unico: `basesdedatos`
- Servicio unico para todas las bases logicas del workspace.
- `production` usa `postgres18_data`
- `qa` usa `postgres18_qa_data` en este host para preservar la data QA actual
- `entorno/.env` es el archivo real
- `templates/entorno/.env.example` es la plantilla versionada

Como el contenedor y el puerto son los mismos, `qa` y `production` no corren al mismo tiempo en el mismo host.

Bases logicas principales en este servicio:

| Base logica | Owner actual |
|---|---|
| `paramascotasec` | compatibilidad/bootstrap ecommerce |
| `identity_platform` | identidad, tenants y permisos |
| `catalog_inventory` | catalogo e inventario |
| `commerce_orders` | pedidos y ventas |
| `billing_service` | Billing SRI, XML, RIDE y configuracion fiscal |
| `reporting_finance` | reporteria financiera |
| `mailer_service` | correo/outbox |

## Despliegues

Despliegue completo del workspace:

```bash
cd /home/admincenter/contenedores
./deploy.sh
```

Despliegue individual de DB desde la raiz:

```bash
cd /home/admincenter/contenedores
./scripts/deploy.sh db
```

Despliegue individual desde este repo:

```bash
cd /home/admincenter/contenedores/basesdedatos
./scripts/deploy.sh
```

La DB no necesita scripts separados por comportamiento.
El mismo `deploy.sh` lee `ENTORNO_MODE`, `DB_ENV` y `POSTGRES_DATA_DIR` desde `entorno/.env`.

## Backups

Los scripts hacen backup del cluster PostgreSQL completo con `pg_dumpall`.
Eso incluye en un solo archivo todas las bases logicas: ecommerce, Billing SRI, identidad, catalogo, pedidos, reporting y mailer.
No existe un backup separado del Facturador como runtime; Billing SRI vive en la base logica `billing_service` dentro de este servicio.

Snapshot cifrado local del ambiente activo:

```bash
cd /home/admincenter/contenedores/basesdedatos
./scripts/backup-and-stop.sh qa
./scripts/backup-and-stop.sh production
```

El archivo queda en:

```text
basesdedatos/backups/qa/*.sql.enc
basesdedatos/backups/production/*.sql.enc
```

Restaurar el ultimo backup local disponible para QA o produccion:

```bash
cd /home/admincenter/contenedores/basesdedatos
./scripts/restore-from-backup.sh qa
./scripts/restore-from-backup.sh production
```

Restaurar un archivo exacto:

```bash
cd /home/admincenter/contenedores/basesdedatos
./scripts/restore-from-backup.sh qa git-transfer/production-to-qa-YYYYMMDDTHHMMSSZ.sql.enc --yes
```

La restauracion reemplaza completamente el data dir del ambiente destino (`POSTGRES_DATA_DIR` en `entorno/.env`).
No restaura solo una base logica; restaura todo el cluster.

Exportar para transferencia por Git, por ejemplo produccion hacia QA:

```bash
cd /home/admincenter/contenedores/basesdedatos
./scripts/transfer-db.sh export --mode production --label qa
```

El backup exportado queda en:

```text
basesdedatos/git-transfer/*.sql.enc
```

Restaurar el backup mas reciente de `git-transfer/` hacia QA:

```bash
cd /home/admincenter/contenedores/basesdedatos
git pull
./scripts/transfer-db.sh restore --mode qa
```

Restaurar un archivo exacto de `git-transfer/`:

```bash
cd /home/admincenter/contenedores/basesdedatos
./scripts/transfer-db.sh restore git-transfer/tu-backup.sql.enc --mode qa
```

La restauracion pide la misma clave temporal usada al exportar.
Si no quieres prompt interactivo:

```bash
TRANSFER_BACKUP_PASSPHRASE='tu_clave' ./scripts/transfer-db.sh restore --mode qa
```

Despues de restaurar, redeplegar los consumidores:

```bash
cd /home/admincenter/contenedores
./scripts/deploy.sh backend
./scripts/deploy.sh frontend
npm --prefix dashboard run docker:up
./scripts/deploy.sh gateway
./scripts/check-container-connectivity.sh qa
```

Para listar backups disponibles:

```bash
ls -lh /home/admincenter/contenedores/basesdedatos/backups/qa/*.sql.enc 2>/dev/null || true
ls -lh /home/admincenter/contenedores/basesdedatos/backups/production/*.sql.enc 2>/dev/null || true
ls -lh /home/admincenter/contenedores/basesdedatos/git-transfer/*.sql.enc 2>/dev/null || true
```

## Validacion

```bash
docker exec basesdedatos postgres --version
docker compose --env-file entorno/.env ps
docker compose --env-file entorno/.env logs -f db
```
