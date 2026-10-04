-- ==================================================================
-- seed.sql — Datos de ejemplo SOLO para desarrollo local
-- ------------------------------------------------------------------
-- docker-compose lo ejecuta una única vez, en el primer arranque del
-- contenedor postgres (después de init.sql). En producción (Neon) NO se usa.
-- ==================================================================

INSERT INTO tasks (title, description, status)
SELECT v.title, v.description, v.status
FROM (VALUES
    ('Configurar Neon',          'Crear el proyecto y copiar la connection string', 'completada'),
    ('Programar backup diario',  'Workflow de GitHub Actions con cron 0 2 * * *',    'pendiente'),
    ('Probar restauración',      'Simular un desastre y restaurar con restore.sh',   'pendiente')
) AS v(title, description, status)
WHERE NOT EXISTS (SELECT 1 FROM tasks);
