---
title: "Borramos la tabla de producción a propósito: una prueba de desastre real con PostgreSQL, Neon y Render"
tags: database, postgres, disasterrecovery, docker
---

# Borramos la tabla de producción a propósito: una prueba de desastre real con PostgreSQL, Neon y Render

**Autor:** Arturo Cutipa Flores
**Curso:** Base de Datos II · Universidad Privada de Tacna
**Proyecto grupal:** DB Backup Strategies, desarrollado junto con Carlos Jimenez Laura

Hablar de backups es fácil; demostrar que funcionan es otra cosa. En nuestro proyecto decidimos no conformarnos con mostrar un archivo de respaldo: **eliminamos la tabla principal de la base de datos de producción** y medimos cuánto tardábamos en recuperarla. En este artículo cuento cómo planificamos esa prueba, qué salió mal en el primer intento y qué métricas obtuvimos.

## Enlaces del proyecto

- **Repositorio:** https://github.com/ArturoCutipaFlores/db-backup-strategies
- **Aplicación en producción:** https://db-backup-strategies.onrender.com
- **Video de demostración:** `[enlace al video]`

## El escenario

La aplicación es un gestor de tareas (crear, completar, eliminar) con un frontend en HTML y JavaScript que consume una API en Node.js. Los datos se guardan en PostgreSQL 17 en **Neon** y la aplicación corre en **Render**. Los backups se generan con `pg_dump` desde **GitHub Actions** todos los días a las 02:00 UTC (21:00 en Perú).

Antes de la prueba definimos dos objetivos, como se haría en una empresa:

| Métrica | Significado | Objetivo |
|---|---|---|
| **RPO** (*Recovery Point Objective*) | Cuántos datos podemos perder como máximo | 24 h (un backup diario) |
| **RTO** (*Recovery Time Objective*) | Cuánto tiempo puede estar caído el servicio | Menos de 15 minutos |

## Empezar en local: un entorno reproducible

Antes de tocar producción ensayamos todo en local con Docker Compose, que levanta dos contenedores: PostgreSQL y la aplicación. Con un solo comando:

```bash
docker compose up --build
```

En local practicamos el ciclo completo: generar un backup dentro del contenedor, borrar la tabla, comprobar que la API respondía **503** y restaurar. Allí también probamos los casos negativos, que son los que dan confianza:

- Restaurar un backup cifrado con una **clave incorrecta** falla y la base queda intacta, porque la restauración corre en una sola transacción.
- Ejecutar `restore.sh` sin confirmación en un entorno no interactivo **se niega a continuar**.
- El script verifica el checksum SHA-256 antes de tocar la base.

Un detalle práctico: en mi equipo el puerto 5432 ya estaba ocupado por otro contenedor, así que publicamos la base local en el **5433** y lo dejamos configurable con una variable de entorno.

## Restaurar con un clic

Restaurar a mano exige descargar el artifact, descifrarlo y tener la cadena de conexión y la clave en la computadora. Durante una emergencia esos pasos son lentos y propensos a errores. Por eso creamos un workflow de restauración en GitHub Actions que usa los mismos secrets que el backup. Basta con escribir `RESTAURAR` como confirmación:

1. Hace un **backup de seguridad del estado actual**, por si se elige el backup equivocado.
2. Descarga el artifact del último backup exitoso.
3. Verifica el checksum, descifra y restaura en **una sola transacción**.
4. Reporta las filas antes y después, y el tiempo de recuperación.

## Primer intento: un falso positivo

En el primer ensayo en producción todo salió en verde... y aun así la prueba no demostraba nada. El resumen del workflow decía **"Filas antes: 3"**, cuando acabábamos de borrar la tabla.

Al investigar en los eventos de Render encontramos la causa. Al borrar la tabla, el *health check* de la aplicación empezó a responder **503**, y Render reinició la instancia. Al arrancar, la aplicación ejecutaba `init.sql`, que recreaba la tabla **e insertaba tres tareas de ejemplo**. Como el backup contenía justo esas tres tareas, era imposible distinguir qué había recuperado el backup y qué había regenerado la aplicación.

La corrección fue separar responsabilidades:

- `init.sql` solo crea la estructura, sin datos. Si la tabla se pierde, la aplicación la recrea **vacía**.
- Los datos de ejemplo pasaron a `seed.sql`, que solo se usa en el entorno local con Docker.

Además, para la prueba definitiva creamos datos de control propios: **"Tarea de Carlos"** y **"Tarea de Arturo"**.

Esta fue para mí la lección más valiosa del proyecto: **una prueba de recuperación debe diseñarse para poder fallar**. Si el resultado sale bien pase lo que pase, la prueba no sirve.

## La prueba definitiva

**1. Estado inicial.** La aplicación en producción con 5 tareas, incluidas las dos de control.

![App con 5 tareas](https://raw.githubusercontent.com/ArturoCutipaFlores/db-backup-strategies/main/docs/capturas/01-app-render-5-tareas.jpg)

**2. Backup.** Ejecutamos el workflow de backup a mano: 44 segundos, archivo cifrado de 4 KB y verificación automática con 5 filas.

**3. Desastre.** En el SQL Editor de Neon ejecutamos:

```sql
DROP TABLE tasks;
```

![DROP TABLE en Neon](https://raw.githubusercontent.com/ArturoCutipaFlores/db-backup-strategies/main/docs/capturas/03-desastre-drop-table-neon.jpg)

**4. Caída.** La aplicación dejó de responder y Render mostró un **502 Bad Gateway**.

![App caída](https://raw.githubusercontent.com/ArturoCutipaFlores/db-backup-strategies/main/docs/capturas/04-app-caida-502.jpg)

**5. Pérdida de datos confirmada.** Tras el reinicio automático, la aplicación volvió a funcionar pero **con 0 tareas**. Esta vez el desastre era visible.

![App vacía](https://raw.githubusercontent.com/ArturoCutipaFlores/db-backup-strategies/main/docs/capturas/05-app-vacia-0-tareas.jpg)

**6. Restauración.** Lanzamos el workflow de restauración. En **24 segundos** la tabla pasó de **0 a 5 filas**.

![Restauración](https://raw.githubusercontent.com/ArturoCutipaFlores/db-backup-strategies/main/docs/capturas/06-restauracion-0-a-5-filas.jpg)

**7. Recuperación.** Recargamos la aplicación: las 5 tareas volvieron, con sus **identificadores originales** (la "Tarea de Carlos" seguía siendo la #4 y la "Tarea de Arturo" la #5).

![App recuperada](https://raw.githubusercontent.com/ArturoCutipaFlores/db-backup-strategies/main/docs/capturas/07-app-recuperada-5-tareas.jpg)

## Resultados

| Métrica | Objetivo | Resultado |
|---|---|---|
| Datos perdidos (RPO) | ≤ 24 h | **0 registros** |
| Tiempo de restauración | — | **24 s** (18 s de recuperación efectiva) |
| Tiempo total de recuperación (RTO) | < 15 min | **≈ 3 min** |

El RPO fue cero porque no hubo escrituras entre el backup y el desastre. En un caso real perderíamos lo escrito desde el último backup diario: hasta 24 horas de datos. Para reducirlo bastaría con ejecutar el backup con más frecuencia o aprovechar la recuperación a un punto en el tiempo (PITR) que ofrece Neon.

El tiempo total incluye detectar la caída y esperar que Render reinicie la instancia; la restauración en sí fue cuestión de segundos.

## Conclusiones

- **Medir convierte un backup en una estrategia.** Sin RPO y RTO definidos de antemano no hay forma de saber si la recuperación fue "suficientemente rápida".
- **Los datos de control hacen la prueba honesta.** Registros identificables como "Tarea de Arturo" permiten afirmar con certeza que los datos vinieron del backup.
- **La restauración también se automatiza.** En una emergencia nadie quiere copiar cadenas de conexión a mano; un workflow con confirmación reduce el error humano.
- **Respaldar antes de restaurar.** Restaurar el backup equivocado es otro desastre; el backup de seguridad previo lo evita.

Como mejora futura propondría repetir esta prueba de desastre de forma periódica (por ejemplo, una vez al mes) y registrar el RTO en cada ejecución para detectar si el tiempo de recuperación empeora a medida que crece la base.

El código, los workflows y todas las capturas están en el repositorio. El desarrollo fue grupal; este artículo presenta mi análisis individual de la prueba de recuperación.
