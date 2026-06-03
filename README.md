# paramascotas-DB

Servicio PostgreSQL compartido por los microservicios de Paramascotas EC.

## Resumen

- PostgreSQL: `18.4`
- Imagen Docker: `postgres:18.4-alpine3.23`
- `PGDATA`: `/var/lib/postgresql/18/docker`
- Produccion usa `.env` y `postgres18_data`
- Desarrollo usa `.env.development` y `postgres18_development_data`
- Los datos y archivos `.env` no se versionan en Git
- Los backups cifrados pueden versionarse solo como paquetes temporales de transferencia

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

## Backups: Que Comando Usar

Regla simple: el backup es un archivo `.sql.enc` y una clave. No importa si el archivo se genero en `production` o en `development`; se puede restaurar en cualquier ambiente si tienes la clave correcta.

- `--mode production`: usa o restaura en produccion.
- `--mode development`: usa o restaura en QA/desarrollo.
- `TRANSFER_BACKUP_PASSPHRASE`: clave temporal para el backup versionado por Git.
- `BACKUP_DECRYPTION_PASSPHRASE`: clave del backup cuando restauras sin terminal interactiva.

Si pierdes la clave, el archivo `.sql.enc` no se puede restaurar.

### Este Es Para Sacar Backup Cifrado Para Git

En el servidor origen:

```bash
cd /home/admincenter/contenedores/paramascotasec-DB
./scripts/transfer-db.sh export --mode production --label qa
```

Ese comando pide una clave temporal y genera el backup cifrado en `git-transfer/`. Git detecta el paquete; tu decides luego si haces commit y push. Si el backup sale desde QA/desarrollo, cambia `--mode production` por `--mode development`.

Si automatizas:

```bash
export TRANSFER_BACKUP_PASSPHRASE='clave-temporal-segura'
./scripts/transfer-db.sh export --mode production --label qa
unset TRANSFER_BACKUP_PASSPHRASE
```

### Este Es Para Restaurar Ese Backup En Cualquier Ambiente

En el servidor destino:

```bash
cd /home/admincenter/contenedores/paramascotasec-DB
git pull
./scripts/transfer-db.sh restore --mode development
```

El script pide la misma clave temporal que usaste al sacar el backup. `--mode development` solo indica donde se restaura. Para restaurar en produccion usa `--mode production`.

### Este Es Para Sacar Backup Local Sin Git

```bash
cd /home/admincenter/contenedores/paramascotasec-DB
./scripts/backup-and-stop.sh production
./scripts/backup-and-stop.sh development
```

Archivos generados:

```bash
backups/production/latest.sql.enc
backups/development/latest.sql.enc
```

Este comando detiene la base al terminar. Para levantarla otra vez:

```bash
./scripts/deploy-production.sh
./scripts/deploy-development.sh
```

### Este Es Para Restaurar Cualquier Archivo Local

El primer argumento es el ambiente destino. El segundo es el archivo `.sql.enc`.

```bash
./scripts/restore-from-backup.sh development backups/production/latest.sql.enc
./scripts/restore-from-backup.sh production backups/development/latest.sql.enc
```

El script pide la clave del backup. Si no tienes terminal interactiva:

```bash
BACKUP_DECRYPTION_PASSPHRASE='CLAVE_DEL_BACKUP' \
./scripts/restore-from-backup.sh development backups/production/latest.sql.enc --yes
```

### Este Es Para Copiar Entre Ambientes Del Mismo Host

```bash
./scripts/import-between-envs.sh production development
./scripts/import-between-envs.sh development production
```

Este comando genera un backup del ambiente origen y lo restaura en el destino usando automaticamente la clave correcta.

## Transferir Solo Ventas Por Git

Usa este si la base nueva ya esta lista, pero necesitas traer ventas puntuales desde una base vieja de produccion. No restaura toda la base: solo trae las ordenes seleccionadas, sus items, asignaciones de inventario, usuario asociado y auditoria de descuentos.

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

- No versionar `.env` ni datos de PostgreSQL.
- Los backups locales en `backups/` no se versionan por defecto.
- Solo versionar paquetes cifrados temporales de `git-transfer/` cuando necesites mover una base entre servidores.
- La clave temporal de transferencia debe ir por otro canal, no por Git.
- Si un paquete o clave se filtra, rota claves y purga historial como tarea separada.
- `backups/backup.sql.enc` fue retirado del repo; usa los backups por ambiente o `git-transfer/`.

## Scripts

Uso normal:

```bash
./scripts/deploy-production.sh
./scripts/deploy-development.sh
./scripts/transfer-db.sh export --mode production --label qa
./scripts/transfer-db.sh restore --mode development
```

Uso avanzado:

```bash
./scripts/backup-and-stop.sh production
./scripts/restore-from-backup.sh production backups/production/latest.sql.enc
./scripts/import-between-envs.sh production development
./scripts/export-for-git.sh production servidor-produccion
./scripts/import-from-git-transfer.sh development git-transfer/NOMBRE.sql.enc
```

## Script Del Backend

Reseteo de ventas en desarrollo:

```bash
cd /home/admincenter/contenedores/paramascotasec-backend
./scripts/reset_sales_data.sh development
./scripts/reset_sales_data.sh development --yes
```
