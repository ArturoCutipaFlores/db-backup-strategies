# ==================================================================
# Dockerfile — Imagen de producción (usada por Render y docker-compose)
# ==================================================================
FROM node:20-alpine

# postgresql-client: pg_dump / pg_restore / psql para backups desde el contenedor
# bash: los scripts de backup/restore usan bash
# gnupg: cifrado opcional de backups (BACKUP_ENCRYPTION_KEY)
RUN apk add --no-cache postgresql-client bash gnupg

ENV NODE_ENV=production \
    BACKUP_DIR=/app/backups

WORKDIR /app

# 1) Copiar solo package*.json primero para aprovechar la caché de capas:
#    si no cambian las dependencias, no se reinstalan en cada build.
COPY backend/package*.json ./backend/
RUN cd backend \
    && if [ -f package-lock.json ]; then npm ci --omit=dev; else npm install --omit=dev; fi \
    && npm cache clean --force

# 2) Copiar el código de la aplicación
COPY backend/  ./backend/
COPY frontend/ ./frontend/
COPY scripts/  ./scripts/

# Permisos de ejecución para los scripts (Git en Windows no conserva el bit +x)
# y carpeta de backups propiedad del usuario sin privilegios "node".
RUN chmod +x scripts/*.sh \
    && mkdir -p /app/backups \
    && chown -R node:node /app/backups

# Ejecutar como usuario sin privilegios (buena práctica de seguridad)
USER node

WORKDIR /app/backend
EXPOSE 3000

# Health check del contenedor (Render usa su propio health check configurable)
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD wget -qO- "http://127.0.0.1:${PORT:-3000}/api/health" > /dev/null || exit 1

CMD ["npm", "start"]
