# Guion del video (5 minutos)

**Integrantes:** Carlos Jimenez Laura (C) · Arturo Cutipa Flores (A)
**Preparación:** desactivar la traducción automática de Chrome; abrir en pestañas: la app en Render, GitHub Actions, la consola de Neon y el README.
**Nota:** para grabar la prueba de desastre otra vez, ejecutar antes un backup nuevo (paso 3).

| Tiempo | Quién | Pantalla | Qué decir |
|---|---|---|---|
| 0:00–0:30 | C | README (título) | "Somos Carlos y Arturo. Presentamos una estrategia de backups de base de datos sin usar MS SQL Server: PostgreSQL en Neon, la app en Render y toda la automatización en GitHub Actions." |
| 0:30–1:10 | A | README (diagrama de arquitectura y stack) | "La app es un CRUD de tareas en Node y Express. Tenemos tres workflows: CI/CD, que prueba y despliega; backup diario a las 2 AM UTC; y restauración con un clic." |
| 1:10–1:40 | A | App en Render | Crear una tarea en vivo y marcarla como completada. "Esta es la aplicación en producción, conectada a Neon." |
| 1:40–2:10 | C | GitHub Actions → CI/CD en verde | "Cada push ejecuta las pruebas contra un PostgreSQL temporal, construye la imagen Docker y, solo si todo pasa, despliega en Render con un Deploy Hook." |
| 2:10–3:00 | C | Actions → Backup diario → Run workflow → resumen | "El backup hace pg_dump, lo comprime, lo cifra con AES-256, calcula un SHA-256 y, lo más importante, lo restaura en una base temporal para comprobar que sirve. Aquí se ve: verificación exitosa y el artifact guardado 7 días." |
| 3:00–3:30 | A | Neon SQL Editor → `DROP TABLE tasks;` | "Ahora simulamos un desastre: borramos la tabla de producción." Mostrar la app con error 502 y luego vacía. |
| 3:30–4:15 | A | Actions → Restaurar backup → `RESTAURAR` → resumen | "Restauramos con un clic. El workflow guarda primero el estado actual por seguridad, descarga y descifra el backup y lo restaura en una sola transacción. De 0 a N filas en unos 20 segundos." Recargar la app: las tareas vuelven. |
| 4:15–4:45 | C | README → Estrategia y RPO/RTO | "El RPO es de 24 horas por el backup diario y el RTO medido fue de unos 3 minutos, frente a un objetivo de 15. Cumplimos la regla 3-2-1 con Neon, GitHub y S3 opcional." |
| 4:45–5:00 | A | README → Por qué no MS SQL Server | "Sin licencias, con herramientas estándar y portables. Gracias." |
