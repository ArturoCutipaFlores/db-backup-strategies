# 🗄️ DB Backup Strategies — PostgreSQL sin MS SQL Server

Proyecto académico que demuestra una **estrategia completa de backups de base de datos** usando solo herramientas open source y servicios cloud gratuitos:

- ✅ Aplicación funcional (CRUD de tareas) con **Node.js + Express** y frontend en **HTML + JS vanilla**.
- ✅ Base de datos **PostgreSQL** administrada en **Neon**.
- ✅ **Backups automáticos diarios** con `pg_dump` programados en **GitHub Actions** (cron).
- ✅ **Verificación automática** de cada backup restaurándolo en una base de datos temporal.
- ✅ **Restauración** con `psql` / `pg_restore` mediante `scripts/restore.sh`.
- ✅ **Deploy automatizado** a **Render** tras pasar los tests (CI/CD).

**Integrantes**

| Integrante | Rol |
|---|---|
| Carlos Jimenez Laura | Backend, CI/CD y estrategia de backups |
| Arturo Cutipa Flores | Frontend, documentación y pruebas de restauración |

**Enlaces**

| Recurso | URL |
|---|---|
| Repositorio | <https://github.com/ArturoCutipaFlores/db-backup-strategies> |
| App desplegada | <https://db-backup-strategies.onrender.com> |
| Artículo | [docs/articulo.md](docs/articulo.md) · publicado: `[PENDIENTE: enlace]` |
| Video demo | `[PENDIENTE: enlace al video]` |

---

## 📐 Arquitectura

```
                   push a main                         cron 02:00 UTC / manual
 ┌───────────┐   ┌──────────────────────┐            ┌──────────────────────────────┐
 │ Developer │──▶│ GitHub Actions       │            │ GitHub Actions (backup.yml)  │
 └───────────┘   │ deploy.yml           │            │ pg_dump → gzip → [gpg]       │
                 │ test → docker → hook │            │ → sha256 → restore de prueba │
                 └──────────┬───────────┘            │ → artifact 7 días → [S3]     │
                            │ Deploy Hook            └──────────────┬───────────────┘
                            ▼                                       │ pg_dump (TLS)
 ┌──────────┐  HTTPS  ┌───────────────────────┐   TLS   ┌───────────▼──────────┐
 │ Navegador│ ──────▶ │ Render (Docker)       │ ──────▶ │ Neon PostgreSQL       │
 │ index.html│        │ Express API + estático│         │ tabla tasks           │
 └──────────┘         └───────────────────────┘         └──────────────────────┘
```

## 🧰 Stack

| Capa | Tecnología |
|---|---|
| Frontend | HTML + CSS + JavaScript vanilla (`fetch`) — `frontend/index.html` |
| Backend | Node.js 20 + Express 4 + `pg` (sin ORM) |
| Base de datos | PostgreSQL 17 en Neon (serverless) · PostgreSQL 15 en local (Docker) |
| Deploy | Render Web Service (runtime Docker) |
| CI/CD | GitHub Actions (`deploy.yml`) |
| Backups | `pg_dump` / `psql` / `pg_restore` + cron de GitHub Actions (`backup.yml`) |
| Almacenamiento de backups | GitHub Actions artifacts (7 días) + S3-compatible opcional |
| Cifrado | TLS en tránsito · GPG AES-256 opcional en reposo |

## 📁 Estructura

```
db-backup-strategies/
├── .github/workflows/
│   ├── deploy.yml        # CI/CD: tests + build Docker + deploy a Render
│   ├── backup.yml        # Backup diario + verificación + artifact
│   └── restore.yml       # Restauración manual desde un artifact (con confirmación)
├── backend/
│   ├── index.js          # Servidor Express (API + frontend + errores)
│   ├── db.js             # Pool de PostgreSQL + inicialización del esquema
│   ├── routes/tasks.js   # CRUD /api/tasks
│   ├── package.json
│   └── .env.example
├── frontend/index.html   # UI del gestor de tareas
├── scripts/
│   ├── backup.sh         # pg_dump → backup_YYYYMMDD_HHMMSS.sql.gz
│   ├── restore.sh        # Restaura .sql.gz / .sql.gz.gpg / .sql / .dump
│   ├── init.sql          # Esquema idempotente (sin datos)
│   └── seed.sql          # Datos de ejemplo (solo desarrollo local)
├── docs/capturas/        # Evidencias para el informe
├── Dockerfile
├── docker-compose.yml
└── README.md
```

## 🔌 API

| Método | Ruta | Descripción |
|---|---|---|
| GET | `/api/health` | Estado de la API y la BD |
| GET | `/api/tasks?status=pendiente\|completada` | Lista de tareas (filtro opcional) |
| GET | `/api/tasks/:id` | Detalle |
| POST | `/api/tasks` | Crea `{ "title": "...", "description": "..." }` |
| PUT | `/api/tasks/:id` | Actualiza (parcial) `{ "title"?, "description"?, "status"? }` |
| DELETE | `/api/tasks/:id` | Elimina |

---

## 💻 Ejecución local

### Opción A — Docker Compose (recomendada)

Requisitos: Docker Desktop.

```bash
docker compose up --build
```

Abre <http://localhost:3000>. Se levantan dos contenedores:

- `postgres` (postgres:15-alpine) con volumen persistente `pgdata` y `init.sql` cargado al primer arranque.
- `app` (la imagen del `Dockerfile`) conectada a `postgres` con `DB_SSL=false`.

Comandos útiles:

```bash
docker compose logs -f app            # ver logs de la API
docker compose down                   # detener (los datos se conservan)
docker compose down -v                # detener y BORRAR los datos locales
```

### Opción B — Node.js directo (contra Neon o un PostgreSQL propio)

```bash
cd backend
cp .env.example .env      # edita DATABASE_URL y DB_SSL
npm install
npm run dev               # recarga automática con node --watch
```

---

## 🚀 Deploy en Render

1. Render → **New → Web Service** → conecta este repositorio.
2. **Language/Runtime:** `Docker` (usa el `Dockerfile` de la raíz).
3. **Environment Variables:**
   - `DATABASE_URL` = connection string de Neon (puede ser la *pooled*).
   - `DB_SSL` = `true`
   - `NODE_ENV` = `production`
4. **Health Check Path:** `/api/health`.
5. **Auto-Deploy:** `Off` (el deploy lo dispara GitHub Actions *solo si los tests pasan*).
6. Settings → **Deploy Hook** → copia la URL y guárdala como secret `RENDER_DEPLOY_HOOK` en GitHub.

Flujo CI/CD (`deploy.yml`): `push a main` → **test** (PostgreSQL efímero + pruebas de humo del CRUD) y **docker** (build de la imagen) → **deploy** (POST al Deploy Hook).

---

## 🔁 Backup automático

`.github/workflows/backup.yml` se ejecuta **todos los días a las 02:00 UTC** (`0 2 * * *`, 21:00 hora de Perú) y también manualmente (*Run workflow*):

1. Instala `postgresql-client-17` desde el repositorio oficial PGDG (pg_dump debe ser ≥ versión del servidor).
2. Ejecuta `scripts/backup.sh`:
   - `pg_dump --format=plain --clean --if-exists --no-owner --no-privileges` | `gzip -9`
   - Nombre: `backup_YYYYMMDD_HHMMSS.sql.gz`
   - Valida integridad (`gzip -t` + marca final de pg_dump) y genera `*.sha256`.
   - Cifra con GPG AES-256 si existe el secret `BACKUP_ENCRYPTION_KEY`.
3. Muestra **tamaño, fecha y checksum** en el log y en el *Job Summary*.
4. **Verifica el backup** restaurándolo en un PostgreSQL 17 temporal y contando las filas de `tasks`.
5. Sube el artifact **`backup-YYYYMMDD`** con **retención de 7 días**.
6. (Opcional) Copia el backup a un bucket S3-compatible (AWS S3, Cloudflare R2, Backblaze B2, MinIO).

Backup manual desde tu máquina o desde el contenedor:

```bash
# Contra Neon (requiere postgresql-client instalado)
DATABASE_URL="postgresql://...neon.tech/neondb?sslmode=require" ./scripts/backup.sh

# Contra la BD local de docker-compose (el backup aparece en ./backups)
docker compose exec app bash /app/scripts/backup.sh
```

> ⚠️ **Neon:** usa la connection string **directa** (sin `-pooler` en el host) para `pg_dump`; PgBouncer en modo transacción no es compatible con volcados.

## ♻️ Restauración

### Opción 1 — Desde GitHub Actions (recomendada, sin manipular credenciales)

Actions → **Restaurar backup de PostgreSQL** → **Run workflow**:

- `run_id`: ID de la ejecución de *Backup diario* a restaurar (vacío = último backup exitoso).
- `confirmar`: escribe `RESTAURAR`.

El workflow (`.github/workflows/restore.yml`) hace un **backup de seguridad del estado actual**, descarga el artifact, lo restaura con `restore.sh` (checksum + descifrado + una sola transacción) y muestra en el *Job Summary* las filas antes/después y el **tiempo de recuperación**.

### Opción 2 — Manual con `restore.sh`

```bash
# 1. Descarga el artifact desde GitHub (Actions → ejecución → Artifacts) y descomprime el .zip
#    o con GitHub CLI:
gh run download <run-id> -n backup-20260101 -D backups/

# 2. Restaura (pide escribir RESTAURAR como confirmación)
DATABASE_URL="postgresql://..." ./scripts/restore.sh backups/backup_20260101_020000.sql.gz

# Backup cifrado
BACKUP_ENCRYPTION_KEY="tu-clave" DATABASE_URL="postgresql://..." \
  ./scripts/restore.sh backups/backup_20260101_020000.sql.gz.gpg

# Restaurar en la BD local de docker-compose
docker compose exec app bash /app/scripts/restore.sh /app/backups/backup_20260101_020000.sql.gz
```

`restore.sh` verifica el checksum, restaura en **una sola transacción** (`--single-transaction` + `ON_ERROR_STOP=1`: si algo falla la BD queda intacta) y al final muestra cuántas filas tiene `tasks`.

> 💡 Buena práctica: restaurar primero en una **rama de Neon** (Branches → Create branch) usando `TARGET_DATABASE_URL`, validar, y solo después restaurar en `main`.

---

## 🛡️ Estrategia de backups

### Tipo de backup

| Tipo | ¿Se usa? | Detalle |
|---|---|---|
| **Full lógico** | ✅ Diario | `pg_dump` del esquema + datos completos. Portable entre versiones y proveedores. |
| Diferencial / incremental | ❌ | `pg_dump` no los soporta. En PostgreSQL se logran con archivado de WAL (`pgBackRest`, `WAL-G`, `pg_basebackup --incremental` en PG17). |
| **PITR del proveedor** | ✅ Complementario | Neon conserva el historial WAL (*restore window* según plan) y permite restaurar/crear ramas en un instante exacto. |

Combinar ambos aplica la **regla 3-2-1**: 3 copias (Neon + artifacts de GitHub + S3), en 2 medios/proveedores distintos, 1 fuera del proveedor principal.

### Retención

| Nivel | Retención |
|---|---|
| GitHub Actions artifacts | 7 días (diarios) |
| S3 (opcional) | Configurable con *lifecycle rules*, p. ej. 30 días diarios + 12 mensuales |
| Neon PITR | Según el plan (ventana de restauración del historial) |
| Local (`BACKUP_KEEP_LAST=N`) | Conserva los N backups más recientes |

### Cifrado

- **En tránsito:** TLS obligatorio con Neon (`sslmode=require`) y HTTPS en Render.
- **En reposo:** GPG simétrico **AES-256** con el secret `BACKUP_ENCRYPTION_KEY`; cifrado en reposo del lado del servidor en S3.
- **Integridad:** checksum SHA-256 generado al hacer el backup y verificado antes de restaurar.
- ⚠️ En un **repositorio público**, los artifacts pueden ser descargados por cualquier usuario autenticado de GitHub: **define `BACKUP_ENCRYPTION_KEY` o usa un repositorio privado.** Guarda la clave fuera de GitHub (gestor de contraseñas): sin ella el backup es irrecuperable.

### RPO / RTO

| Métrica | Objetivo | Justificación |
|---|---|---|
| **RPO** (pérdida máxima de datos) | **24 h** con los backups diarios · **minutos** usando el PITR de Neon | Se ejecuta un full cada 24 h. Bajar el RPO = aumentar la frecuencia del cron (p. ej. `0 */6 * * *`). |
| **RTO** (tiempo para recuperar) | **< 15 min** | Descargar artifact (~1 min) + `restore.sh` (segundos para esta BD) + verificación. Medido en la prueba de desastre. |

### Verificación

Cada backup programado se **restaura automáticamente** en un PostgreSQL temporal del runner. Un backup que nunca se probó restaurar no es un backup.

---

## 🧪 Resultados de la prueba de desastre (producción, 04/10/2026)

| # | Paso | Resultado | Evidencia |
|---|---|---|---|
| 1 | App en Render con 5 tareas (incluye "Tarea de Carlos" y "Tarea de Arturo") | ✅ | [01](docs/capturas/01-app-render-5-tareas.jpg) |
| 2 | Backup manual (`backup.yml`): `pg_dump` 17 → gzip → GPG AES-256 → SHA-256 → restauración de prueba | ✅ 44 s · 4 KB · verificación **5 filas** | [02](docs/capturas/02-backup-verificado-5-filas.jpg) |
| 3 | Desastre: `DROP TABLE tasks;` en Neon | ✅ | [03](docs/capturas/03-desastre-drop-table-neon.jpg) |
| 4 | La app falla (health check 503 → Render responde 502 y reinicia la instancia) | ✅ | [04](docs/capturas/04-app-caida-502.jpg) |
| 5 | Tras el reinicio la app recrea la tabla **vacía**: datos perdidos | ✅ 0 tareas | [05](docs/capturas/05-app-vacia-0-tareas.jpg) |
| 6 | Restauración (`restore.yml`): backup de seguridad + descarga + descifrado + restore transaccional | ✅ 24 s · **0 → 5 filas** | [06](docs/capturas/06-restauracion-0-a-5-filas.jpg) |
| 7 | App recuperada con las 5 tareas y sus IDs originales | ✅ | [07](docs/capturas/07-app-recuperada-5-tareas.jpg) |
| 8 | Todos los workflows en verde | ✅ | [08](docs/capturas/08-github-actions-todo-verde.jpg) |

**Métricas medidas**

- **RPO real de la prueba:** 0 registros perdidos (no hubo escrituras entre el backup de las 02:05 UTC y el desastre). RPO de diseño: 24 h.
- **RTO real:** **≈ 3 min** de extremo a extremo (detección + reinicio de Render + restauración); el workflow de restauración tarda **24 s** (18 s de recuperación efectiva). Objetivo: < 15 min ✅.

---

## ❓ ¿Por qué NO MS SQL Server?

- **Licenciamiento y costo:** SQL Server es propietario; las ediciones gratuitas (Express/Developer) tienen límites de tamaño o no se permiten en producción. PostgreSQL es open source (licencia PostgreSQL) y gratuito sin restricciones.
- **Ecosistema cloud gratuito:** Neon, Render, Supabase, Railway ofrecen PostgreSQL administrado gratis; no hay equivalentes gratuitos y administrados de SQL Server.
- **Herramientas de backup estándar en Linux:** `pg_dump`/`pg_restore` vienen en el paquete `postgresql-client` de cualquier distribución y en los runners de GitHub Actions; los `.bak` de SQL Server requieren la instancia de SQL Server para crearse y restaurarse.
- **Portabilidad:** un dump SQL plano de PostgreSQL es texto legible y restaurable en cualquier proveedor (evita *vendor lock-in*).
- **Requisito académico:** el objetivo del curso es demostrar estrategias de backup **sin** depender de MS SQL Server.

---

## 🔐 Secrets de GitHub

| Secret | Obligatorio | Uso |
|---|---|---|
| `DATABASE_URL` | ✅ | Connection string **directa** de Neon para `backup.yml` |
| `RENDER_DEPLOY_HOOK` | ✅ | URL del Deploy Hook de Render para `deploy.yml` |
| `BACKUP_ENCRYPTION_KEY` | Recomendado | Clave para cifrar backups con GPG AES-256 |
| `S3_BUCKET`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_DEFAULT_REGION` | Opcional | Copia externa en S3 |
| `S3_ENDPOINT_URL` | Opcional | Endpoint de un servicio S3-compatible (R2, B2, MinIO) |

---

## 📖 Guía paso a paso

### a) Correr el proyecto en local

1. Instala **Git** y **Docker Desktop** (inícialo y espera a que diga *Engine running*).
2. `git clone <url-del-repo> && cd db-backup-strategies`
3. `docker compose up --build`
4. Abre <http://localhost:3000>, crea, completa y elimina tareas.
5. Prueba un backup local: `docker compose exec app bash /app/scripts/backup.sh` → aparece en `./backups/`.

### b) Configurar Neon

1. Crea una cuenta en <https://neon.tech> → **New Project** (región cercana, p. ej. `AWS us-east-1`; PostgreSQL 17).
2. En el *Dashboard* → **Connect** → copia dos cadenas:
   - **Pooled** (host con `-pooler`) → para la app en Render.
   - **Direct** (desactiva *Connection pooling*) → para `pg_dump` en GitHub Actions.
3. La tabla `tasks` se crea sola cuando la app arranca (`init.sql`). Opcionalmente ejecútalo en el **SQL Editor** de Neon.

### c) Crear el Web Service en Render y obtener el Deploy Hook

1. Sube el repo a GitHub.
2. <https://render.com> → **New → Web Service** → conecta el repo.
3. Runtime **Docker**, plan **Free**, rama `main`.
4. Variables: `DATABASE_URL` (pooled de Neon), `DB_SSL=true`, `NODE_ENV=production`.
5. *Advanced* → **Health Check Path** `/api/health` → **Auto-Deploy: No**.
6. **Create Web Service** y espera el primer deploy.
7. **Settings → Deploy Hook** → copia la URL (`https://api.render.com/deploy/srv-...?key=...`). Es secreta.

### d) Configurar los Secrets en GitHub

Repo → **Settings → Secrets and variables → Actions → New repository secret**:

- `DATABASE_URL` → connection string **directa** de Neon.
- `RENDER_DEPLOY_HOOK` → URL del Deploy Hook.
- `BACKUP_ENCRYPTION_KEY` → una clave larga (p. ej. `openssl rand -base64 32`).

### e) Probar el backup manual y automático

1. **Manual:** Actions → *Backup diario de PostgreSQL* → **Run workflow**.
2. Revisa el log: tamaño, fecha, SHA-256 y "✅ Backup verificado: N filas".
3. Al final de la ejecución, sección **Artifacts** → `backup-YYYYMMDD` (expira en 7 días).
4. **Automático:** se ejecuta solo a las 02:00 UTC; al día siguiente verás una ejecución con el evento `schedule`.
   - Los cron solo corren en la rama por defecto y pueden retrasarse algunos minutos en horas de alta carga.
   - En repos públicos, GitHub desactiva los cron tras 60 días sin actividad.

### f) Simular un desastre y restaurar

1. Anota cuántas tareas hay (`/api/health` muestra el total). Ejecuta un backup (paso e).
2. **Desastre:** en el SQL Editor de Neon ejecuta `DROP TABLE tasks;` (o `DELETE FROM tasks;`).
3. Comprueba que la app falla o está vacía → `/api/health` devuelve `database: down` o `tasks: 0`. Inicia el cronómetro (RTO).
4. **Restaura desde GitHub Actions:** Actions → *Restaurar backup de PostgreSQL* → Run workflow → `confirmar = RESTAURAR`. Revisa el *Job Summary* (filas antes/después y tiempo). Salta al paso 6.
5. (Alternativa manual) Descarga el artifact, descomprímelo en `backups/` y restaura:
   ```bash
   export DATABASE_URL="postgresql://...neon.tech/neondb?sslmode=require"   # directa
   export BACKUP_ENCRYPTION_KEY="..."                                        # si está cifrado
   ./scripts/restore.sh backups/backup_YYYYMMDD_HHMMSS.sql.gz.gpg
   ```
   (Sin `psql` en Windows: usa Git Bash con PostgreSQL instalado, WSL, o `docker run --rm -it -v "$PWD:/w" -w /w -e DATABASE_URL -e BACKUP_ENCRYPTION_KEY postgres:17-alpine sh -c "apk add bash gnupg && bash scripts/restore.sh backups/<archivo>"`.)
6. Si dropeaste la tabla, reinicia el servicio en Render (**Manual Deploy → Restart**) o simplemente recarga la app.
7. Verifica que el número de tareas coincide, detén el cronómetro y **guarda capturas en `docs/capturas/`** (RPO = tiempo desde el último backup; RTO = tiempo de restauración).
