# paramascotas-DB (Capa de Base de Datos) 🐘

Contenedor que provisiona la versión Postgres al resto de microservicios usando túneles seguros dedicados.

## 🏭 1. Entorno de Producción
Prioriza máxima seguridad restringiendo los saltos de IPs a lo estrictamente interno.

```bash
cd /home/admincenter/contenedores/paramascotasec-DB
./scripts/deploy-production.sh
```

---

## 🛠️ 2. Entorno de Desarrollo
Extiende un canal abierto para visores externos o desarrolladores conectados por red de LAN/VPN.

```bash
cd /home/admincenter/contenedores/paramascotasec-DB
./scripts/deploy-development.sh
```

---

## 📌 3. Datos Relevantes y Contexto a Tomar en Cuenta

### 🔒 Backups y Restauración (Snapshots Asegurados)
El proceso de captura y recuperación de datos es vital y está completamente automatizado, pero requiere tu atención:

**A) Proceso para sacar un Snapshot (Backup Cifrado):**
Para resguardar el ecosistema de la base de datos de manera inviolable (cifrado AES) antes de hacer actualizaciones peligrosas del servidor, se ejecuta el siguiente comando:
```bash
cd /home/admincenter/contenedores/paramascotasec-DB
./scripts/backup-and-stop.sh production
```
*Este proceso generará un snapshot encapsulado y luego detendrá la base de datos de forma segura para evitar escritura residual.*

**B) Proceso para levantar la DB usando el Snapshot (Restauración):**
Si el servidor fue formateado, la base de datos destruida (por ejemplo borrando `postgres16_data`) o estás clonando el servidor en otra máquina, la restauración se hace con el script dedicado de restore.

El despliegue normal no restaura backups automáticamente; solo levanta PostgreSQL con el estado actual del directorio de datos. Para reconstruir la base desde el snapshot cifrado usa:
```bash
cd /home/admincenter/contenedores/paramascotasec-DB
./scripts/deploy-from-backup.sh development   # O production
```
También puedes ejecutar directamente:
```bash
./scripts/restore-from-backup.sh development   # O production
```
*¿Qué ocurre internamente?*
1. Apaga el servicio si está corriendo.
2. Limpia el directorio local de datos `postgres16_data`.
3. Vuelve a levantar PostgreSQL en vacío.
4. Desencripta `backups/backup.sql.enc`.
5. Restaura el dump completo dentro del cluster.

### 🌐 Bind IP y Acceso a Base de Datos
*   **Modo Local (Development):** Variable `POSTGRES_BIND_IP=0.0.0.0` para poder espiarla con software (e.g., DBeaver o PgAdmin).
*   **Modo Producción:** Enquista herméticamente la comunicación bajo capa local cruzando en IP unida `127.0.0.1`.
*   Para revisar los logs si la restauración falla:
    ```bash
    docker compose logs -f db
    ```



Está aquí:

/home/admincenter/contenedores/paramascotasec-backend/scripts/reset_sales_data.sh

Para usarlo en desarrollo:

cd /home/admincenter/contenedores/paramascotasec-backend
./scripts/reset_sales_data.sh development
O sin confirmación interactiva:

./scripts/reset_sales_data.sh development --yes

