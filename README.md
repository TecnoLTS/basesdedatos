# paramascotas-DB

Servicio PostgreSQL compartido por los microservicios de Paramascotas EC.

## Resumen

- PostgreSQL: `18.4`
- Imagen Docker: `postgres:18.4-alpine3.23`
- `PGDATA`: `/var/lib/postgresql/18/docker`
- Produccion usa `.env` y `postgres18_data`
- Desarrollo usa `.env.development` y `postgres18_development_data`
- Los backups, datos y archivos `.env` no se versionan en Git

Este proyecto usa un solo `container_name` (`next-test-db`) y un solo puerto. Por eso production y development no corren al mismo tiempo en el mismo host; los scripts recrean el contenedor apuntando al directorio de datos del ambiente elegido.

## Despliegue

Produccion debe quedar enlazada a `127.0.0.1`. Para acceso remoto usa tunel SSH o VPN; no expongas PostgreSQL directamente a internet.

```bash
cd /home/admincenter/contenedores/paramascotasec-DB
./scripts/deploy-production.sh
```

Desarrollo:

```bash
cd /home/admincenter/contenedores/paramascotasec-DB
./scripts/deploy-development.sh
```

## Transferir Por Git

Usa este flujo cuando no puedes copiar archivos entre servidores. El backup viaja por Git cifrado con una clave temporal que tu eliges. Esa clave no se guarda en Git.

### Solo Ventas

Usa este flujo si la base nueva ya esta lista, pero necesitas traer ventas puntuales desde una base vieja de produccion. No restaura toda la base: solo trae las ordenes seleccionadas, sus items, asignaciones de inventario, usuario asociado y auditoria de descuentos.

En el servidor origen, conectado a la base vieja:

```bash
cd /home/admincenter/contenedores/paramascotasec-DB
./scripts/transfer-sales.sh export ORD-ID-1 ORD-ID-2 --stage
git commit -m "Transfer encrypted sales"
git push
```

Si las dos ventas son exactamente las ultimas ventas registradas en esa base:

```bash
./scripts/transfer-sales.sh export --latest 2 --stage
```

El script te muestra las ventas seleccionadas y te pide una clave temporal. Guarda esa clave para ingresarla en el servidor destino.

En el servidor destino:

```bash
cd /home/admincenter/contenedores/paramascotasec-DB
git pull
./scripts/transfer-sales.sh restore
```

La restauracion valida checksum, pide la misma clave temporal y aplica solo ordenes que no existan en destino. Si una orden ya existe, no se duplica y no vuelve a descontar inventario.

Para indicar un paquete concreto:

```bash
./scripts/transfer-sales.sh restore git-transfer/sales-production-sales-YYYYMMDDTHHMMSSZ.json.enc
```

Despues de validar, puedes eliminar el paquete cifrado de `git-transfer/` y hacer otro commit normal si ya no lo necesitas.

### Base Completa

#### 1. En El Servidor Origen

```bash
cd /home/admincenter/contenedores/paramascotasec-DB
./scripts/transfer-db.sh export --stage
git commit -m "Transfer encrypted database backup"
git push
```

El script detecta el ambiente activo, te pide una clave temporal dos veces, genera el paquete cifrado en `git-transfer/` y lo agrega al index de Git.

#### 2. En El Servidor Destino

```bash
cd /home/admincenter/contenedores/paramascotasec-DB
git pull
./scripts/transfer-db.sh restore
```

Ingresa la misma clave temporal que usaste en el origen. El script detecta el ambiente destino, toma el backup mas reciente de `git-transfer/`, verifica el checksum si existe y restaura.

Si hay varios paquetes, indica el archivo exacto:

```bash
./scripts/transfer-db.sh restore git-transfer/NOMBRE.sql.enc
```

Despues de validar la restauracion, puedes eliminar el paquete cifrado de `git-transfer/` y hacer otro commit normal si ya no lo necesitas.

## Backups Locales

Generar backup cifrado por ambiente:

```bash
./scripts/backup-and-stop.sh production
./scripts/backup-and-stop.sh development
```

Los backups quedan en:

```bash
backups/production/
backups/development/
```

Restaurar backup local:

```bash
./scripts/restore-from-backup.sh production backups/production/latest.sql.enc
./scripts/restore-from-backup.sh development backups/development/latest.sql.enc
```

En modo no interactivo agrega `--yes`.

## Importar Entre Ambientes Del Mismo Host

```bash
./scripts/import-between-envs.sh production development
./scripts/import-between-envs.sh development production
```

El origen debe tener un cluster PostgreSQL inicializado. El script se bloquea si detecta que el origen no existe para evitar reemplazar un ambiente con una base vacia.

## Claves

Cada ambiente debe tener su propia `BACKUP_ENCRYPTION_PASSPHRASE` en su archivo `.env`.

Generar una clave segura:

```bash
openssl rand -base64 48
```

Para transferencias por Git, `transfer-db.sh` usa una clave temporal elegida por ti. No subas esa clave al repositorio. Si necesitas automatizar:

```bash
export TRANSFER_BACKUP_PASSPHRASE='clave-temporal-segura'
./scripts/transfer-db.sh restore --yes
unset TRANSFER_BACKUP_PASSPHRASE
```

## Validacion

```bash
docker exec next-test-db postgres --version
docker compose --env-file .env ps
docker compose --env-file .env logs -f db
```

La version debe reportar PostgreSQL `18.4` y el servicio debe quedar `healthy`.

Validar backend:

```bash
docker exec paramascotasec-backend-web wget -q -O /dev/null http://127.0.0.1:8080/api/health
```

## Seguridad Operativa

- No versionar `.env`, datos de PostgreSQL ni backups normales.
- Solo usar `git-transfer/` para paquetes cifrados temporales.
- La clave temporal de transferencia debe ir por otro canal, no por Git.
- Si un paquete o clave se filtra, rota claves y purga historial como tarea separada.
- `backups/backup.sql.enc` fue retirado del repo; usa los backups por ambiente o `git-transfer/`.

## Scripts

Uso normal:

```bash
./scripts/deploy-production.sh
./scripts/deploy-development.sh
./scripts/transfer-db.sh export --stage
./scripts/transfer-db.sh restore
```

Uso avanzado:

```bash
./scripts/backup-and-stop.sh production
./scripts/restore-from-backup.sh production backups/production/latest.sql.enc
./scripts/import-between-envs.sh production development
./scripts/export-for-git.sh production servidor-produccion --stage
./scripts/import-from-git-transfer.sh production git-transfer/NOMBRE.sql.enc
```

## Script Del Backend

Reseteo de ventas en desarrollo:

```bash
cd /home/admincenter/contenedores/paramascotasec-backend
./scripts/reset_sales_data.sh development
./scripts/reset_sales_data.sh development --yes
```
