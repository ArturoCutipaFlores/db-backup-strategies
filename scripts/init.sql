-- ==================================================================
-- init.sql — Esquema de la aplicación de tareas
-- ------------------------------------------------------------------
-- Es IDEMPOTENTE: se puede ejecutar muchas veces sin error ni duplicados.
-- Lo ejecutan:
--   * El backend al arrancar (backend/db.js -> initDb()).
--   * El contenedor postgres de docker-compose en su primer arranque
--     (montado en /docker-entrypoint-initdb.d).
-- ==================================================================

CREATE TABLE IF NOT EXISTS tasks (
    id          SERIAL PRIMARY KEY,
    title       VARCHAR(200) NOT NULL CHECK (char_length(trim(title)) > 0),
    description TEXT         NOT NULL DEFAULT '',
    status      VARCHAR(20)  NOT NULL DEFAULT 'pendiente'
                CHECK (status IN ('pendiente', 'completada')),
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- Índice para filtrar por estado (GET /api/tasks?status=...)
CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks (status);

-- Datos de ejemplo: solo se insertan si la tabla está vacía,
-- así la demo arranca con contenido y no se duplican en reinicios.
INSERT INTO tasks (title, description, status)
SELECT v.title, v.description, v.status
FROM (VALUES
    ('Configurar Neon',          'Crear el proyecto y copiar la connection string', 'completada'),
    ('Programar backup diario',  'Workflow de GitHub Actions con cron 0 2 * * *',    'pendiente'),
    ('Probar restauración',      'Simular un desastre y restaurar con restore.sh',   'pendiente')
) AS v(title, description, status)
WHERE NOT EXISTS (SELECT 1 FROM tasks);
