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
| `dashboard` | usuarios, tenants, permisos, orquestacion y correo tecnico |
| `ecommerce` | catalogo, inventario, pedidos, ventas y reportes operativos ecommerce |
| `facturacion` | Billing SRI, XML, RIDE y configuracion fiscal |

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
Eso incluye en un solo archivo las bases logicas de negocio: `dashboard`, `ecommerce` y `facturacion`.
No existe un backup separado del Facturador como runtime; Billing SRI vive en la base logica `facturacion` dentro de este servicio.

Snapshot cifrado local del ambiente activo:

```bash
cd /home/admincenter/contenedores/basesdedatos
./scripts/backup-and-stop.sh
```

El comando pide una clave para cifrar el backup y la solicita dos veces. Esa
misma clave se debe ingresar al restaurar. El backup deja PostgreSQL en
ejecucion; no apaga los servicios al finalizar.

El archivo queda en un solo directorio de backups con nombre neutral:

```text
basesdedatos/backups/backup-YYYYMMDDTHHMMSSZ.sql.enc
basesdedatos/backups/latest.sql.enc
```

Restaurar el ultimo backup local disponible:

```bash
cd /home/admincenter/contenedores/basesdedatos
./scripts/restore-from-backup.sh --yes
```

Listar backups reales disponibles:

```bash
cd /home/admincenter/contenedores/basesdedatos
./scripts/restore-from-backup.sh --list
```

Restaurar un archivo exacto de esa lista:

```bash
cd /home/admincenter/contenedores/basesdedatos
./scripts/restore-from-backup.sh backups/backup-20260628T193633Z.sql.enc --yes
```

La restauracion reemplaza completamente el data dir del ambiente destino (`POSTGRES_DATA_DIR` en `entorno/.env`).
No restaura solo una base logica; restaura todo el cluster.
El nombre del archivo no define origen ni destino: restauras el `.sql.enc` que
quieras en el ambiente al que apunte el `entorno/.env` activo. El restore pide
la clave del backup y solo continua si esa clave descifra el archivo. `--yes`
solo salta la confirmacion destructiva; no salta la clave.
Si pasas un nombre, debe existir exactamente. `backup-YYYYMMDDTHHMMSSZ.sql.enc`
es solo el patron del nombre, no un archivo real.
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
Exportar para transferencia por Git desde el servidor origen activo:

```bash
cd /home/admincenter/contenedores/basesdedatos
./scripts/transfer-db.sh export --label traslado
```

La exportacion genera el backup cifrado y deja el servicio de base de datos
funcionando.

El backup exportado queda en:

```text
basesdedatos/git-transfer/*.sql.enc
```

Restaurar el backup mas reciente de `git-transfer/` en el ambiente activo:

```bash
cd /home/admincenter/contenedores/basesdedatos
git pull
./scripts/transfer-db.sh restore --yes
```

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

Restaurar un archivo exacto de `git-transfer/`:

```bash
cd /home/admincenter/contenedores/basesdedatos
./scripts/transfer-db.sh restore git-transfer/tu-backup.sql.enc
```

La restauracion pide la misma clave usada al exportar.
Si no quieres prompt interactivo:

```bash
TRANSFER_BACKUP_PASSPHRASE='tu_clave' ./scripts/transfer-db.sh restore
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

La restauracion ejecuta la sincronizacion de bases por modulo al final. Ese
paso reconcilia contra el `.env` activo las bases logicas, el rol runtime,
grants y los `USER MAPPING` de `postgres_fdw`, para que secretos embebidos en
un backup no queden apuntando al ambiente origen.

Si necesitas reconciliar manualmente sin restaurar:

```bash
cd /home/admincenter/contenedores
./basesdedatos/scripts/sync-module-databases.sh
docker exec backend-api php /var/www/html/scripts/check_module_databases.php
```

Si el backend no esta levantado, puedes sincronizar primero y validar despues
de desplegarlo:

```bash
cd /home/admincenter/contenedores
./basesdedatos/scripts/sync-module-databases.sh
./scripts/deploy.sh backend
docker exec backend-api php /var/www/html/scripts/check_module_databases.php
```

Para listar backups disponibles:

```bash
ls -lh /home/admincenter/contenedores/basesdedatos/backups/*.sql.enc 2>/dev/null || true
ls -lh /home/admincenter/contenedores/basesdedatos/git-transfer/*.sql.enc 2>/dev/null || true
```

## Validacion

```bash
docker exec basesdedatos postgres --version
docker compose --env-file entorno/.env ps
docker compose --env-file entorno/.env logs -f db
```






cd /home/admincenter/contenedores/basesdedatos
./scripts/transfer-db.sh export --label traslado



cd /home/admincenter/contenedores/basesdedatos
./scripts/transfer-db.sh restore --yes





Tunel

ssh -N -L 15432:172.19.0.4:5432 root@192.168.100.229
