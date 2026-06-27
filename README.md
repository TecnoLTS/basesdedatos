# `paramascotasec-DB`

Unidad de despliegue del PostgreSQL compartido del workspace.

## Resumen

- PostgreSQL `18.x`
- Contenedor unico: `next-test-db`
- `production` usa `postgres18_data`
- `development` usa `postgres18_development_data`
- `entorno/.env` es el archivo real
- `templates/entorno/.env.example` es la plantilla versionada

Como el contenedor y el puerto son los mismos, `development` y `production` no corren al mismo tiempo en el mismo host.

## Deploy del componente

Desde el repo:

```bash
cd /home/admincenter/contenedores/paramascotasec-DB
./scripts/deploy.sh development
./scripts/deploy.sh production
```

Desde la raiz del workspace:

```bash
cd /home/admincenter/contenedores
./scripts/deploy.sh development db
./scripts/deploy.sh production db
```

La DB no necesita scripts separados por comportamiento.
El mismo `deploy.sh` cambia modo, `.env` y data dir.

## Backups

Snapshot cifrado local:

```bash
./scripts/backup-and-stop.sh production
./scripts/backup-and-stop.sh development
```

Restaurar ultimo backup:

```bash
./scripts/restore-from-backup.sh development
./scripts/restore-from-backup.sh production
```

Exportar para transferencia por Git:

```bash
./scripts/transfer-db.sh export --mode production --label qa
```

Restaurar backup versionado por Git:

```bash
git pull
./scripts/transfer-db.sh restore --mode development
./scripts/transfer-db.sh restore --mode production
```

Restaurar un archivo exacto:

```bash
./scripts/transfer-db.sh restore git-transfer/tu-backup.sql.enc --mode development
```

La restauracion pide la misma clave temporal usada al exportar.
Si no quieres prompt interactivo:

```bash
TRANSFER_BACKUP_PASSPHRASE='tu_clave' ./scripts/transfer-db.sh restore --mode development
```

## Validacion

```bash
docker exec next-test-db postgres --version
docker compose --env-file entorno/.env ps
docker compose --env-file entorno/.env logs -f db
```
