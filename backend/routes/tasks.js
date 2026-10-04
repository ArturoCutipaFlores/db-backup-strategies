/**
 * routes/tasks.js
 * ------------------------------------------------------------------
 * CRUD REST de tareas:
 *   GET    /api/tasks          -> lista (filtro opcional ?status=pendiente|completada)
 *   GET    /api/tasks/:id      -> detalle
 *   POST   /api/tasks          -> crear   { title, description?, status? }
 *   PUT    /api/tasks/:id      -> actualizar (parcial) { title?, description?, status? }
 *   DELETE /api/tasks/:id      -> eliminar
 *
 * Todas las consultas son parametrizadas ($1, $2...) para evitar inyección SQL.
 */
const express = require('express');
const { query } = require('../db');

const router = express.Router();

const VALID_STATUS = ['pendiente', 'completada'];
const MAX_TITLE = 200;
const MAX_DESCRIPTION = 2000;

/** Error HTTP con código de estado, lo captura el middleware de errores. */
class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

/** Valida que :id sea un entero positivo. */
function parseId(raw) {
  const id = Number(raw);
  if (!Number.isInteger(id) || id <= 0) {
    throw new HttpError(400, 'El id debe ser un número entero positivo.');
  }
  return id;
}

/**
 * Valida el cuerpo de la petición.
 * @param {object} body
 * @param {boolean} partial  true en PUT (todos los campos opcionales)
 */
function validateTask(body, { partial = false } = {}) {
  if (!body || typeof body !== 'object') {
    throw new HttpError(400, 'El cuerpo de la petición debe ser JSON.');
  }
  const { title, description, status } = body;
  const data = {};

  if (title !== undefined) {
    if (typeof title !== 'string' || title.trim() === '') {
      throw new HttpError(400, 'El título es obligatorio y debe ser texto.');
    }
    if (title.trim().length > MAX_TITLE) {
      throw new HttpError(400, `El título no puede superar ${MAX_TITLE} caracteres.`);
    }
    data.title = title.trim();
  } else if (!partial) {
    throw new HttpError(400, 'El título es obligatorio.');
  }

  if (description !== undefined && description !== null) {
    if (typeof description !== 'string') {
      throw new HttpError(400, 'La descripción debe ser texto.');
    }
    if (description.length > MAX_DESCRIPTION) {
      throw new HttpError(400, `La descripción no puede superar ${MAX_DESCRIPTION} caracteres.`);
    }
    data.description = description.trim();
  }

  if (status !== undefined) {
    if (!VALID_STATUS.includes(status)) {
      throw new HttpError(400, `Estado inválido. Valores permitidos: ${VALID_STATUS.join(', ')}.`);
    }
    data.status = status;
  }

  if (partial && Object.keys(data).length === 0) {
    throw new HttpError(400, 'Envía al menos un campo: title, description o status.');
  }
  return data;
}

/**
 * Envuelve handlers async para que cualquier excepción llegue a next(err)
 * (Express 4 no captura promesas rechazadas por sí solo).
 */
const asyncHandler = (fn) => (req, res, next) => Promise.resolve(fn(req, res, next)).catch(next);

// GET /api/tasks  — lista todas las tareas (más recientes primero)
router.get(
  '/',
  asyncHandler(async (req, res) => {
    const { status } = req.query;
    if (status !== undefined && !VALID_STATUS.includes(status)) {
      throw new HttpError(400, `Filtro inválido. Valores permitidos: ${VALID_STATUS.join(', ')}.`);
    }
    const result = status
      ? await query('SELECT * FROM tasks WHERE status = $1 ORDER BY created_at DESC, id DESC', [status])
      : await query('SELECT * FROM tasks ORDER BY created_at DESC, id DESC');
    res.json(result.rows);
  })
);

// GET /api/tasks/:id — detalle de una tarea
router.get(
  '/:id',
  asyncHandler(async (req, res) => {
    const id = parseId(req.params.id);
    const result = await query('SELECT * FROM tasks WHERE id = $1', [id]);
    if (result.rowCount === 0) throw new HttpError(404, `No existe la tarea con id ${id}.`);
    res.json(result.rows[0]);
  })
);

// POST /api/tasks — crea una tarea
router.post(
  '/',
  asyncHandler(async (req, res) => {
    const data = validateTask(req.body);
    const result = await query(
      `INSERT INTO tasks (title, description, status)
       VALUES ($1, $2, $3)
       RETURNING *`,
      [data.title, data.description ?? '', data.status ?? 'pendiente']
    );
    res.status(201).json(result.rows[0]);
  })
);

// PUT /api/tasks/:id — actualización parcial (solo los campos enviados)
router.put(
  '/:id',
  asyncHandler(async (req, res) => {
    const id = parseId(req.params.id);
    const data = validateTask(req.body, { partial: true });
    // COALESCE conserva el valor actual cuando el parámetro llega como NULL.
    const result = await query(
      `UPDATE tasks
          SET title       = COALESCE($1, title),
              description = COALESCE($2, description),
              status      = COALESCE($3, status)
        WHERE id = $4
        RETURNING *`,
      [data.title ?? null, data.description ?? null, data.status ?? null, id]
    );
    if (result.rowCount === 0) throw new HttpError(404, `No existe la tarea con id ${id}.`);
    res.json(result.rows[0]);
  })
);

// DELETE /api/tasks/:id — elimina una tarea
router.delete(
  '/:id',
  asyncHandler(async (req, res) => {
    const id = parseId(req.params.id);
    const result = await query('DELETE FROM tasks WHERE id = $1 RETURNING id', [id]);
    if (result.rowCount === 0) throw new HttpError(404, `No existe la tarea con id ${id}.`);
    res.json({ message: `Tarea ${id} eliminada.`, id });
  })
);

module.exports = router;
