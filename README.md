# paramascotas-DB

Servicio PostgreSQL compartido por los microservicios de Paramascotas EC.

## Resumen

- PostgreSQL: `18.4`
- Imagen Docker: `postgres:18.4-alpine3.23`
- `PGDATA`: `/var/lib/postgresql/18/docker`
- Produccion usa `entorno/.env`, `entorno/servidor.env` y `postgres18_data`
- Desarrollo usa `entorno/.env`, `entorno/servidor.env` y `postgres18_development_data`
- Los datos y archivos `entorno/.env` no se versionan en Git
- Los backups cifrados pueden versionarse solo como paquetes temporales de transferencia
- Las plantillas versionadas viven en `templates/entorno/.env.example` y `templates/entorno/servidor.env.example`

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

Regla simple: el backup es un archivo `.sql.enc` y una clave. Se puede restaurar en cualquier ambiente si tienes esa clave. Si pierdes la clave, el backup no se puede recuperar.

### Este Es Para Sacar Backup Cifrado

Usa este para crear un backup local de `production` o `development`.

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

El comando detiene la base al terminar. Para levantarla otra vez:

```bash
./scripts/deploy-production.sh
./scripts/deploy-development.sh
```

### Este Es Para Restaurar El Ultimo Backup

Usa este en el ambiente destino. El script toma automaticamente el `.sql.enc` mas reciente de `backups/` y pide la clave del backup.

```bash
./scripts/restore-from-backup.sh development
./scripts/restore-from-backup.sh production
```

Si no tienes terminal interactiva:

```bash
BACKUP_DECRYPTION_PASSPHRASE='CLAVE_DEL_BACKUP' \
./scripts/restore-from-backup.sh development --yes
```

### Este Es Para Restaurar Un Archivo Exacto

```bash
./scripts/restore-from-backup.sh development backups/production/latest.sql.enc
./scripts/restore-from-backup.sh production backups/development/latest.sql.enc
```

### Este Es Para Sacar Backup Cifrado Para Git

Usa este si quieres mover el backup entre servidores por Git.

```bash
cd /home/admincenter/contenedores/paramascotasec-DB
./scripts/transfer-db.sh export --mode production --label qa
```

El comando pide una clave temporal y genera el paquete cifrado en `git-transfer/`. Git detecta el cambio; tu decides luego si haces commit y push. Si el backup sale desde QA/desarrollo, cambia `--mode production` por `--mode development`.

### Este Es Para Restaurar Un Backup De Git

```bash
git pull
./scripts/transfer-db.sh restore --mode development
```

El script pide la misma clave temporal que usaste al sacar el backup. `--mode development` solo indica donde se restaura. Para restaurar en produccion usa `--mode production`.

## Validacion

```bash
docker exec next-test-db postgres --version
docker compose --env-file entorno/.env ps
docker compose --env-file entorno/.env logs -f db
```

La version debe reportar PostgreSQL `18.4` y el servicio debe quedar `healthy`.

Validar backend:

```bash
docker exec paramascotasec-backend-web wget -q -O /dev/null http://127.0.0.1:8080/api/health
```

## Seguridad Operativa

- No versionar `entorno/.env`, claves ni datos de PostgreSQL.
- `entorno/` solo contiene archivos reales del servidor; plantillas y documentacion van fuera.
- Los backups locales en `backups/` no se versionan por defecto.
- Los paquetes cifrados de `git-transfer/` quedan visibles para Git, pero tu decides cuando hacer commit y push.
- La clave temporal debe ir por otro canal, no por Git.
