-- ==================================================================
-- init.sql — Esquema de la aplicación de tareas (SOLO estructura)
-- ------------------------------------------------------------------
-- Es IDEMPOTENTE: se puede ejecutar muchas veces sin error ni duplicados.
-- Lo ejecutan:
--   * El backend al arrancar (backend/db.js -> initDb()).
--   * El contenedor postgres de docker-compose en su primer arranque
--     (montado en /docker-entrypoint-initdb.d).
--
-- No inserta datos: si la tabla se pierde en producción, la app la
-- recrea VACÍA (los datos solo vuelven restaurando un backup).
-- Los datos de ejemplo para desarrollo local están en seed.sql.
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
