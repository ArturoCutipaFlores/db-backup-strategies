/**
 * index.js
 * ------------------------------------------------------------------
 * Punto de entrada del backend:
 *  - API REST de tareas en /api/tasks
 *  - Health check en /api/health (usado por CI y por Render)
 *  - Sirve el frontend estático (frontend/index.html)
 *  - Manejo centralizado de errores y apagado ordenado (SIGTERM)
 */
require('dotenv').config(); // Carga backend/.env en desarrollo (en Render se usan variables del panel)

const path = require('path');
const express = require('express');
const cors = require('cors');
const { pool, initDb } = require('./db');
const tasksRouter = require('./routes/tasks');

const app = express();
const PORT = Number(process.env.PORT) || 3000;
const FRONTEND_DIR = process.env.FRONTEND_DIR || path.join(__dirname, '..', 'frontend');

// ---------- Middlewares globales ----------
app.disable('x-powered-by'); // no revelar la tecnología del servidor
app.use(cors()); // permite consumir la API desde otros orígenes (p. ej. un frontend aparte)
app.use(express.json({ limit: '100kb' })); // parser JSON con límite de tamaño

// Log mínimo de peticiones a la API (método, ruta, código, duración)
app.use('/api', (req, res, next) => {
  const start = Date.now();
  res.on('finish', () => {
    console.log(`${req.method} ${req.originalUrl} -> ${res.statusCode} (${Date.now() - start} ms)`);
  });
  next();
});

// ---------- Rutas de la API ----------

// Health check: comprueba que la app Y la base de datos respondan.
app.get('/api/health', async (req, res) => {
  try {
    const { rows } = await pool.query('SELECT NOW() AS now, (SELECT COUNT(*) FROM tasks)::int AS tasks');
    res.json({ status: 'ok', database: 'up', dbTime: rows[0].now, tasks: rows[0].tasks });
  } catch (err) {
    res.status(503).json({ status: 'error', database: 'down', error: err.message });
  }
});

app.use('/api/tasks', tasksRouter);

// Cualquier otra ruta /api/* inexistente -> 404 en JSON
app.use('/api', (req, res) => {
  res.status(404).json({ error: `Endpoint no encontrado: ${req.method} ${req.originalUrl}` });
});

// ---------- Frontend estático ----------
app.use(express.static(FRONTEND_DIR));

// 404 para rutas que no son API ni archivos estáticos
app.use((req, res) => {
  res.status(404).send('Página no encontrada');
});

// ---------- Manejo centralizado de errores ----------
// eslint-disable-next-line no-unused-vars
app.use((err, req, res, next) => {
  // JSON mal formado enviado por el cliente
  if (err.type === 'entity.parse.failed') {
    return res.status(400).json({ error: 'JSON inválido en el cuerpo de la petición.' });
  }
  if (err.type === 'entity.too.large') {
    return res.status(413).json({ error: 'El cuerpo de la petición es demasiado grande.' });
  }
  // Errores de validación lanzados por las rutas (HttpError)
  if (err.status && err.status < 500) {
    return res.status(err.status).json({ error: err.message });
  }
  // Violaciones de restricciones de PostgreSQL (CHECK, NOT NULL, tipo inválido)
  if (['23514', '23502', '22P02', '22001'].includes(err.code)) {
    return res.status(400).json({ error: 'Datos inválidos para la base de datos.', detail: err.message });
  }

  console.error('[error]', err);
  res.status(500).json({
    error: 'Error interno del servidor.',
    ...(process.env.NODE_ENV !== 'production' && { detail: err.message }),
  });
});

// ---------- Arranque ----------
let server;

async function start() {
  try {
    await initDb(); // crea la tabla si no existe (scripts/init.sql)
    server = app.listen(PORT, '0.0.0.0', () => {
      console.log(`[app] Servidor escuchando en http://localhost:${PORT}`);
      console.log(`[app] Frontend servido desde: ${FRONTEND_DIR}`);
    });
  } catch (err) {
    console.error('[app] No se pudo iniciar: la base de datos no está disponible.', err.message);
    process.exit(1);
  }
}

// Apagado ordenado: Render/Docker envían SIGTERM antes de detener el contenedor.
async function shutdown(signal) {
  console.log(`[app] ${signal} recibido, cerrando...`);
  const forceExit = setTimeout(() => process.exit(1), 10_000);
  forceExit.unref();
  try {
    if (server) await new Promise((resolve) => server.close(resolve));
    await pool.end();
    console.log('[app] Cierre completado.');
    process.exit(0);
  } catch (err) {
    console.error('[app] Error durante el cierre:', err.message);
    process.exit(1);
  }
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
process.on('unhandledRejection', (reason) => {
  console.error('[app] Promesa rechazada sin manejar:', reason);
});

start();

module.exports = app;
