---
title: "Backups de PostgreSQL que se prueban solos: pg_dump, cifrado y verificación automática con GitHub Actions"
tags: postgres, githubactions, devops, database
---

# Backups de PostgreSQL que se prueban solos: pg_dump, cifrado y verificación automática con GitHub Actions

**Autor:** Carlos Jimenez Laura
**Curso:** Base de Datos II · Universidad Privada de Tacna
**Proyecto grupal:** DB Backup Strategies, desarrollado junto con Arturo Cutipa Flores

En este proyecto partimos de una pregunta sencilla: *¿cómo sabemos que un backup sirve antes de necesitarlo?* Muchas estrategias terminan en un archivo `.sql` guardado en alguna parte, y nadie comprueba que se pueda restaurar hasta el día del desastre. En este artículo explico cómo construimos un pipeline de respaldos para PostgreSQL que genera la copia, la cifra y **la restaura automáticamente en una base temporal** cada vez que se ejecuta. Me centro en las decisiones técnicas del backend, el CI/CD y la automatización, que fueron mi parte del trabajo.

## Enlaces del proyecto

- **Repositorio:** https://github.com/ArturoCutipaFlores/db-backup-strategies
- **Aplicación en producción:** https://db-backup-strategies.onrender.com
- **Video de demostración:** `[enlace al video]`

## El stack y por qué lo elegimos

| Capa | Tecnología |
|---|---|
| Aplicación | Node.js 20 + Express + `pg` (sin ORM) y un frontend en HTML + JS vanilla |
| Base de datos | PostgreSQL 17 en **Neon** |
| Hosting | **Render** (contenedor Docker) |
| Automatización | **GitHub Actions** |
| Backups | `pg_dump`, `psql`, `gzip`, `gpg`, `sha256sum` |

La restricción del curso era no usar MS SQL Server. Más que una limitación, resultó una ventaja: las herramientas de backup de PostgreSQL vienen en el paquete `postgresql-client` de cualquier distribución Linux. Eso significa que el runner de GitHub Actions puede respaldar la base sin servidores propios ni licencias.

La aplicación es un CRUD de tareas, deliberadamente simple. El protagonista no es la app sino lo que pasa con sus datos.

## Tres workflows, tres responsabilidades

Separé la automatización en tres archivos para que cada uno tenga un solo propósito:

1. **`deploy.yml`:** en cada `push` a `main` levanta un PostgreSQL efímero como *service container*, arranca la API y ejecuta pruebas de humo del CRUD con `curl` y `jq` (crear, listar, actualizar, validar errores 400 y 404, eliminar). También construye la imagen Docker. Solo si todo pasa, hace un `POST` al *Deploy Hook* de Render.
2. **`backup.yml`:** se ejecuta todos los días a las 02:00 UTC (`cron: '0 2 * * *'`) y también a mano.
3. **`restore.yml`:** restaura la base de producción desde un backup, con confirmación explícita.

En Render desactivé el *Auto-Deploy*. Así el único camino a producción pasa por los tests: si una prueba falla, el hook nunca se dispara.

## Anatomía de `backup.sh`

El script es el corazón del proyecto. Lo escribí en bash con `set -Eeuo pipefail` para que cualquier error detenga la ejecución. Sus pasos son:

```bash
pg_dump --dbname="$DATABASE_URL" \
  --format=plain --clean --if-exists \
  --no-owner --no-privileges \
  | gzip -9 > "$TMP_FILE"
```

- **`--format=plain`:** SQL legible y portable, restaurable en cualquier servidor PostgreSQL.
- **`--clean --if-exists`:** el backup incluye `DROP ... IF EXISTS`, así que restaurar reemplaza los objetos dañados en lugar de chocar con ellos.
- **`--no-owner --no-privileges`:** Neon usa sus propios roles; sin estas opciones la restauración en otro servidor fallaría por permisos.
- **`pipefail`:** si `pg_dump` falla a mitad de camino, el error no queda oculto detrás de un `gzip` exitoso.

Después del volcado vienen las validaciones:

1. `gzip -t` comprueba que el archivo comprimido no esté corrupto.
2. Se busca la marca `PostgreSQL database dump complete`, que `pg_dump` escribe **solo** si terminó el volcado. Si falta, el backup se descarta.
3. Si existe el secret `BACKUP_ENCRYPTION_KEY`, el archivo se cifra con **GPG AES-256**. La clave se pasa por un descriptor de archivo, nunca como argumento, para que no aparezca en la lista de procesos.
4. Se genera un **checksum SHA-256** que `restore.sh` verifica antes de restaurar.

Un `trap` sobre `EXIT` borra los archivos parciales si algo falla. Así nunca queda en disco un backup incompleto que parezca válido.

## El detalle que más me enseñó: la versión de `pg_dump`

La primera versión del workflow instalaba `postgresql-client` desde los repositorios de Ubuntu, que traen la versión 16. Neon usa PostgreSQL 17, y `pg_dump` **se niega a respaldar un servidor más nuevo que él mismo**. La solución fue instalar el cliente desde el repositorio oficial PGDG:

```yaml
- name: Instalar postgresql-client 17
  run: |
    sudo apt-get install -y -qq postgresql-common gnupg
    sudo /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y
    sudo apt-get install -y -qq postgresql-client-17
```

Mientras trabajábamos, GitHub anunció que `ubuntu-latest` pasará a Ubuntu 26. Como el repositorio PGDG podría no soportarlo de inmediato, fijé los runners en `ubuntu-24.04`. Un backup diario que se rompe en silencio por una actualización del runner es exactamente el tipo de fallo que queríamos evitar.

Otro detalle de Neon: para `pg_dump` hay que usar la **conexión directa**, no la que pasa por el *pooler* (PgBouncer en modo transacción). La app en Render sí usa la conexión con pooling.

## Verificación: restaurar cada backup automáticamente

Este es el paso del que estoy más orgulloso. El job de backup declara un PostgreSQL 17 temporal como *service container*:

```yaml
services:
  verify-db:
    image: postgres:17-alpine
    env:
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: restore_check
```

Después de generar el backup, el workflow lo restaura en esa base efímera con el mismo `restore.sh` que usaríamos en un desastre real, y cuenta las filas de la tabla `tasks`. Si el archivo está corrupto, si la clave de cifrado es incorrecta o si el SQL no es válido, **el workflow falla ese mismo día**, no el día que necesitemos el backup.

El resultado se publica en el *Job Summary*:

![Backup verificado con 5 filas](https://raw.githubusercontent.com/ArturoCutipaFlores/db-backup-strategies/main/docs/capturas/02-backup-verificado-5-filas.jpg)

En la ejecución de la demostración el backup tardó **44 segundos**, pesó **4 KB** cifrado y la verificación recuperó **5 filas**. Finalmente se sube como artifact `backup-AAAAMMDD` con retención de 7 días.

## Seguridad: por qué el cifrado no era opcional

Nuestro repositorio es público, y en un repositorio público **cualquier usuario autenticado de GitHub puede descargar los artifacts**. Sin cifrado, un volcado de producción quedaría al alcance de cualquiera. Por eso el workflow avisa con un *warning* si `BACKUP_ENCRYPTION_KEY` no está configurado.

Las credenciales viven solo en GitHub Secrets (`DATABASE_URL`, `RENDER_DEPLOY_HOOK`, `BACKUP_ENCRYPTION_KEY`), y los scripts imprimen únicamente el host de la base, nunca el usuario ni la contraseña.

## Probarlo en producción

La prueba final la hicimos sobre la base real. Tras ejecutar `DROP TABLE tasks;` en Neon, la aplicación quedó vacía. El workflow de restauración la recuperó en **24 segundos**, pasando de **0 a 5 filas**:

![Restauración de 0 a 5 filas](https://raw.githubusercontent.com/ArturoCutipaFlores/db-backup-strategies/main/docs/capturas/06-restauracion-0-a-5-filas.jpg)

Mi compañero Arturo detalla esta prueba de desastre en su artículo.

## Qué aprendí

- **Un backup sin restauración probada es solo un archivo.** Integrar la verificación al mismo workflow fue la decisión de mayor impacto.
- **La automatización también necesita mantenimiento:** versiones del cliente, imágenes de los runners, saltos de línea CRLF en Windows. Añadí un `.gitattributes` que fuerza LF en los `.sh` porque Git en Windows los convertía y bash fallaba en Linux.
- **Separar despliegue y respaldo.** `deploy.yml` actualiza el servicio y `backup.yml` protege los datos. Son problemas distintos y merecen workflows distintos.

## Qué mejoraría

Con más tiempo agregaría archivado continuo de WAL para bajar el RPO de 24 horas a segundos, una copia externa en almacenamiento S3 (el workflow ya tiene el paso preparado, solo faltan las credenciales) y alertas cuando un backup programado falle.

El código, los workflows y las evidencias están en el repositorio enlazado al inicio. El desarrollo fue grupal; este artículo recoge mi análisis individual del proyecto.
