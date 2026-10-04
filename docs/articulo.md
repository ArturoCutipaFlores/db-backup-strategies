# Backups de PostgreSQL automatizados y verificados con GitHub Actions: una estrategia sin MS SQL Server

**Autores:** Carlos Jimenez Laura · Arturo Cutipa Flores
**Repositorio:** https://github.com/ArturoCutipaFlores/db-backup-strategies
**Demo en vivo:** https://db-backup-strategies.onrender.com

---

## Resumen

Una base de datos sin backups probados es un riesgo latente: el día que se pierden los datos no es momento de descubrir que el respaldo estaba corrupto o que nadie sabe restaurarlo. En este artículo presentamos una estrategia completa de copias de seguridad para una aplicación web con **PostgreSQL**, construida únicamente con herramientas open source y servicios cloud gratuitos: **Neon** (PostgreSQL serverless), **Render** (hosting) y **GitHub Actions** (automatización). La solución realiza un backup completo diario, lo cifra, lo **verifica restaurándolo automáticamente** y permite recuperar la base de producción con un solo clic. En una prueba de desastre real eliminamos la tabla principal en producción y la recuperamos íntegra en **24 segundos** de restauración (≈ 3 minutos de extremo a extremo), sin perder un solo registro.

## 1. Introducción y problema

Las organizaciones suelen asociar las estrategias de backup a productos comerciales como Microsoft SQL Server, con sus planes de mantenimiento y archivos `.bak`. Sin embargo, ese enfoque implica costos de licenciamiento, dependencia de una instancia de SQL Server para crear y restaurar los respaldos, y poca disponibilidad de servicios administrados gratuitos.

Nuestro objetivo fue demostrar que es posible implementar una estrategia de backups **profesional** —automatizada, cifrada, verificada y con métricas de RPO/RTO— usando PostgreSQL y herramientas estándar de su ecosistema.

## 2. Arquitectura

La aplicación es un gestor de tareas (CRUD) compuesto por:

| Capa | Tecnología |
|---|---|
| Frontend | HTML + JavaScript vanilla (`fetch`) |
| Backend | Node.js 20 + Express + `pg` (sin ORM) |
| Base de datos | PostgreSQL 17 en Neon |
| Hosting | Render (contenedor Docker) |
| CI/CD y backups | GitHub Actions |

Tres workflows de GitHub Actions orquestan todo:

1. **`deploy.yml` (CI/CD):** en cada `push` a `main` levanta un PostgreSQL efímero, ejecuta pruebas de humo del CRUD, construye la imagen Docker y, solo si todo pasa, dispara el *Deploy Hook* de Render.
2. **`backup.yml`:** backup diario programado (`cron: '0 2 * * *'`) o manual.
3. **`restore.yml`:** restauración manual con confirmación explícita.

## 3. Estrategia de backups

### 3.1 Tipo de backup

Usamos **backups lógicos completos** con `pg_dump` en formato SQL plano comprimido con gzip. Elegimos el formato plano por su portabilidad: puede restaurarse en cualquier servidor PostgreSQL, incluso de otra versión o proveedor, evitando el *vendor lock-in*. Las opciones `--clean --if-exists` hacen que la restauración reemplace los objetos existentes, y `--no-owner --no-privileges` la independizan de los roles de Neon.

`pg_dump` no ofrece backups diferenciales ni incrementales; en PostgreSQL estos se logran archivando el WAL (con herramientas como pgBackRest o WAL-G). En nuestro caso, el **PITR (Point-in-Time Recovery) de Neon** complementa los backups diarios para recuperaciones de grano fino.

### 3.2 Pipeline del backup

```
pg_dump → gzip -9 → validación → cifrado GPG AES-256 → SHA-256 → restauración de prueba → artifact (7 días) → [S3 opcional]
```

- **Validación de integridad:** `gzip -t` y búsqueda de la marca `PostgreSQL database dump complete`, que `pg_dump` solo escribe si el volcado terminó; si falla, el archivo parcial se elimina.
- **Cifrado:** GPG simétrico AES-256 con una clave guardada como *secret* de GitHub. Es imprescindible porque en un repositorio público cualquier usuario autenticado puede descargar los artifacts.
- **Checksum SHA-256:** se verifica antes de restaurar para detectar archivos dañados o manipulados.
- **Verificación automática:** cada backup se restaura en un PostgreSQL 17 temporal dentro del runner y se cuentan las filas. *Un backup que nunca se probó restaurar no es un backup.*

### 3.3 Retención y regla 3-2-1

| Nivel | Retención |
|---|---|
| Artifacts de GitHub Actions | 7 días |
| S3-compatible (opcional) | Configurable con reglas de ciclo de vida |
| Historial PITR de Neon | Según el plan |

Con Neon + GitHub + S3 se cumple la regla **3-2-1**: tres copias, en dos proveedores distintos, una fuera del proveedor principal.

### 3.4 RPO y RTO

- **RPO (pérdida máxima aceptable):** 24 h con el backup diario; reducible aumentando la frecuencia del cron o usando el PITR de Neon.
- **RTO (tiempo máximo de recuperación):** objetivo < 15 minutos.

## 4. Prueba de desastre

Ejecutamos la prueba directamente en producción el 4 de octubre de 2026:

1. La aplicación tenía 5 tareas, entre ellas "Tarea de Carlos" y "Tarea de Arturo", creadas como datos de control.
2. Ejecutamos el backup manualmente: **44 s**, archivo cifrado de **4 KB**, verificación exitosa con **5 filas**.
3. Simulamos el desastre con `DROP TABLE tasks;` en la consola de Neon.
4. El health check de la aplicación comenzó a fallar (HTTP 503) y Render dejó de enrutar tráfico (HTTP 502) y reinició la instancia. Al arrancar, la aplicación recreó la tabla **vacía**: los datos se habían perdido.
5. Lanzamos el workflow de restauración escribiendo `RESTAURAR`. El workflow hizo primero un backup de seguridad del estado dañado, descargó y descifró el último backup, verificó su checksum y lo restauró en **una sola transacción**.
6. Resultado: **0 → 5 filas** en 24 s; las tareas reaparecieron con sus identificadores originales.

| Métrica | Objetivo | Resultado |
|---|---|---|
| RPO | 24 h | 0 registros perdidos |
| RTO (restauración) | — | 24 s |
| RTO (extremo a extremo) | < 15 min | ≈ 3 min |

## 5. Lecciones aprendidas

1. **La versión de `pg_dump` importa.** Debe ser igual o superior a la del servidor. El cliente de Ubuntu era la versión 16 y Neon usa la 17, así que instalamos el cliente desde el repositorio oficial PGDG.
2. **Conexión directa para respaldar.** El *pooler* de Neon (PgBouncer en modo transacción) no es adecuado para `pg_dump`; usamos la cadena de conexión directa.
3. **Los datos de ejemplo pueden ocultar un desastre.** En la primera prueba, la aplicación reinsertaba datos de ejemplo al reiniciarse, enmascarando la pérdida. Separamos el esquema (`init.sql`) de los datos de ejemplo (`seed.sql`, solo local) para que la pérdida fuera visible y medible.
4. **Restaurar en una transacción.** `--single-transaction` y `ON_ERROR_STOP=1` garantizan que una restauración fallida deje la base como estaba.
5. **Respaldar antes de restaurar.** Restaurar el backup equivocado es un desastre en sí mismo; por eso el workflow guarda el estado actual antes de sobrescribirlo.

## 6. ¿Por qué no MS SQL Server?

- **Costo:** licencias comerciales; las ediciones gratuitas tienen límites o no se permiten en producción.
- **Ecosistema:** no existen servicios administrados gratuitos de SQL Server comparables a Neon.
- **Herramientas:** `pg_dump` y `psql` vienen en cualquier distribución Linux y en los runners de GitHub; los `.bak` requieren una instancia de SQL Server para crearse y restaurarse.
- **Portabilidad:** un volcado SQL de PostgreSQL es texto legible y restaurable en cualquier proveedor.

## 7. Conclusiones

Con herramientas gratuitas y estándar construimos una estrategia de backups que cumple los requisitos de un entorno profesional: automatización diaria, cifrado, verificación de integridad, verificación de restaurabilidad, retención definida y un procedimiento de recuperación de un solo clic. La prueba de desastre en producción confirmó un RTO de unos 3 minutos frente a un objetivo de 15, sin pérdida de datos.

Como trabajo futuro proponemos incorporar archivado continuo de WAL para reducir el RPO a segundos y una copia externa en almacenamiento S3 con reglas de retención a largo plazo.

---

**Video demostrativo:** `[PENDIENTE: enlace al video]`
