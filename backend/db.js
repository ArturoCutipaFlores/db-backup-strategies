/**
 * db.js
 * ------------------------------------------------------------------
 * Capa de acceso a datos: crea un Pool de conexiones de PostgreSQL
 * con el paquete "pg" (sin ORM) y expone una función para inicializar
 * el esquema (tabla "tasks") ejecutando scripts/init.sql.
 */
const fs = require('fs');
const path = require('path');
const { Pool } = require('pg');

if (!process.env.DATABASE_URL) {
  console.error('[db] ERROR: la variable de entorno DATABASE_URL no está definida.');
  console.error('[db] Copia backend/.env.example a backend/.env o define la variable en Render.');
  process.exit(1);
}

/**
 * SSL:
 * - Neon EXIGE conexiones cifradas (TLS). Por defecto SSL está activado.
 * - El PostgreSQL local de docker-compose no tiene TLS, por eso allí se usa DB_SSL=false.
 * Nota: si la cadena de conexión trae "?sslmode=require" (como la de Neon),
 * el driver "pg" la respeta y usa TLS igualmente.
 */
const useSSL = String(process.env.DB_SSL || 'true').toLowerCase() !== 'false';

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  ssl: useSSL ? { rejectUnauthorized: true } : false,
  max: 10, // conexiones máximas del pool
  idleTimeoutMillis: 30_000, // cierra conexiones ociosas tras 30 s
  connectionTimeoutMillis: 10_000, // Neon puede tardar en "despertar" (scale to zero)
});

// Un error en una conexión ociosa no debe tumbar el proceso; solo se registra.
pool.on('error', (err) => {
  console.error('[db] Error inesperado en una conexión ociosa del pool:', err.message);
});

/**
 * SQL de respaldo por si scripts/init.sql no existe en el entorno de ejecución.
 * Debe mantenerse sincronizado con scripts/init.sql.
 */
const FALLBACK_INIT_SQL = `
  CREATE TABLE IF NOT EXISTS tasks (
    id          SERIAL PRIMARY KEY,
    title       VARCHAR(200) NOT NULL CHECK (char_length(trim(title)) > 0),
    description TEXT NOT NULL DEFAULT '',
    status      VARCHAR(20)  NOT NULL DEFAULT 'pendiente'
                CHECK (status IN ('pendiente', 'completada')),
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
  );
  CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks (status);
`;

/** Lee scripts/init.sql (ruta configurable con INIT_SQL_PATH). */
function loadInitSql() {
  const initPath =
    process.env.INIT_SQL_PATH || path.join(__dirname, '..', 'scripts', 'init.sql');
  try {
    const sql = fs.readFileSync(initPath, 'utf8');
    console.log(`[db] Usando script de inicialización: ${initPath}`);
    return sql;
  } catch {
    console.warn(`[db] No se encontró ${initPath}; se usa el SQL embebido.`);
    return FALLBACK_INIT_SQL;
  }
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * Crea la tabla si no existe. Reintenta la conexión varias veces porque:
 * - En docker-compose la BD puede tardar unos segundos en aceptar conexiones.
 * - Neon suspende el cómputo cuando está inactivo y tarda en reactivarse.
 */
async function initDb({ retries = 10, delayMs = 3000 } = {}) {
  const sql = loadInitSql();

  for (let attempt = 1; attempt <= retries; attempt++) {
    try {
      await pool.query(sql); // init.sql es idempotente (IF NOT EXISTS)
      const { rows } = await pool.query('SELECT version() AS version');
      console.log(`[db] Conectado: ${rows[0].version.split(',')[0]}`);
      console.log('[db] Esquema verificado (tabla "tasks" lista).');
      return;
    } catch (err) {
      console.error(`[db] Intento ${attempt}/${retries} fallido: ${err.message}`);
      if (attempt === retries) throw err;
      await sleep(delayMs);
    }
  }
}

/** Atajo para ejecutar consultas parametrizadas (evita inyección SQL). */
const query = (text, params) => pool.query(text, params);

module.exports = { pool, query, initDb };
