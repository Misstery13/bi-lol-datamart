-- =====================================================================
-- ENTREGABLE 2 - CONSULTAS DE VALIDACION
-- Ejecutar una por una y capturar los resultados como evidencia de carga.
-- Ejecutar:
--   docker compose exec postgres psql -U bi_user -d bi_database -f /proyecto/04_validaciones.sql
-- =====================================================================
SET search_path TO dm;

-- ---------------------------------------------------------------------
-- V1. CANTIDAD DE REGISTROS CARGADOS EN CADA TABLA
-- ---------------------------------------------------------------------
SELECT 'dim_tiempo'            AS tabla, COUNT(*) AS registros FROM dim_tiempo
UNION ALL SELECT 'dim_liga',            COUNT(*) FROM dim_liga
UNION ALL SELECT 'dim_equipo',          COUNT(*) FROM dim_equipo
UNION ALL SELECT 'dim_parche',          COUNT(*) FROM dim_parche
UNION ALL SELECT 'dim_lado',            COUNT(*) FROM dim_lado
UNION ALL SELECT 'dim_campeon',         COUNT(*) FROM dim_campeon
UNION ALL SELECT 'hecho_partida_equipo',COUNT(*) FROM hecho_partida_equipo
UNION ALL SELECT 'hecho_draft',         COUNT(*) FROM hecho_draft
ORDER BY tabla;

-- ---------------------------------------------------------------------
-- V2. COHERENCIA DE LA GRANULARIDAD
-- Cada partida debe tener exactamente dos equipos. El resultado esperado
-- de la segunda consulta es cero filas.
-- ---------------------------------------------------------------------
SELECT COUNT(DISTINCT gameid) AS partidas_unicas,
       COUNT(*)               AS filas_hecho,
       ROUND(COUNT(*)::NUMERIC / COUNT(DISTINCT gameid), 2) AS filas_por_partida
FROM hecho_partida_equipo;

SELECT gameid, COUNT(*) AS equipos
FROM hecho_partida_equipo
GROUP BY gameid
HAVING COUNT(*) <> 2;

-- En cada partida debe haber exactamente un ganador
SELECT gameid, SUM(victoria) AS ganadores
FROM hecho_partida_equipo
GROUP BY gameid
HAVING SUM(victoria) <> 1;

-- ---------------------------------------------------------------------
-- V3. INTEGRIDAD REFERENCIAL
-- Todas las consultas deben devolver cero. Las claves foraneas ya lo
-- garantizan, pero se verifica para dejar evidencia.
-- ---------------------------------------------------------------------
SELECT COUNT(*) AS hechos_sin_tiempo
FROM hecho_partida_equipo h
LEFT JOIN dim_tiempo d ON d.id_tiempo = h.id_tiempo
WHERE d.id_tiempo IS NULL;

SELECT COUNT(*) AS hechos_sin_equipo
FROM hecho_partida_equipo h
LEFT JOIN dim_equipo d ON d.id_equipo = h.id_equipo
WHERE d.id_equipo IS NULL;

SELECT COUNT(*) AS hechos_sin_liga
FROM hecho_partida_equipo h
LEFT JOIN dim_liga d ON d.id_liga = h.id_liga
WHERE d.id_liga IS NULL;

-- Dimensiones sin uso: indican filas perdidas durante la carga
SELECT e.nombre_equipo
FROM dim_equipo e
LEFT JOIN hecho_partida_equipo h ON h.id_equipo = e.id_equipo
WHERE h.id_hecho IS NULL;

-- ---------------------------------------------------------------------
-- V4. VALORES NULOS RELEVANTES
-- oro_dif_15 nulo es esperado: corresponde a ligas con datos parciales.
-- ---------------------------------------------------------------------
SELECT COUNT(*)                                            AS total,
       COUNT(oro_dif_15)                                   AS con_oro_dif_15,
       COUNT(*) - COUNT(oro_dif_15)                        AS sin_oro_dif_15,
       ROUND(100.0 * (COUNT(*) - COUNT(oro_dif_15)) / COUNT(*), 2) AS pct_nulos,
       COUNT(*) - COUNT(vision_score)                      AS sin_vision_score,
       COUNT(*) - COUNT(id_equipo_rival)                   AS sin_rival
FROM hecho_partida_equipo;

-- Que ligas concentran los datos parciales
SELECT l.liga,
       COUNT(*) AS partidas,
       COUNT(*) - COUNT(h.oro_dif_15) AS sin_oro_dif_15
FROM hecho_partida_equipo h
JOIN dim_liga l ON l.id_liga = h.id_liga
GROUP BY l.liga
HAVING COUNT(*) - COUNT(h.oro_dif_15) > 0
ORDER BY sin_oro_dif_15 DESC;

-- ---------------------------------------------------------------------
-- V5. TOTALES Y MEDIDAS PRINCIPALES
-- ---------------------------------------------------------------------
SELECT COUNT(DISTINCT gameid)                   AS partidas,
       ROUND(AVG(duracion_seg) / 60.0, 1)       AS duracion_media_min,
       SUM(kills)                               AS kills_totales,
       ROUND(AVG(oro_total))                    AS oro_promedio,
       ROUND(AVG(oro_dif_15))                   AS oro_dif_15_promedio,
       ROUND(100.0 * AVG(victoria), 2)          AS tasa_victoria_global
FROM hecho_partida_equipo;

-- La tasa de victoria global debe ser 50 %: cada partida tiene un ganador
-- y un perdedor. Si no lo es, hay partidas incompletas en el hecho.

-- Ventaja del lado azul, una validacion de sentido comun del dominio
SELECT ld.lado,
       COUNT(*)                        AS partidas,
       ROUND(100.0 * AVG(h.victoria), 2) AS tasa_victoria
FROM hecho_partida_equipo h
JOIN dim_lado ld ON ld.id_lado = h.id_lado
GROUP BY ld.lado;

-- Rango temporal efectivamente cargado
SELECT MIN(t.fecha) AS desde, MAX(t.fecha) AS hasta, COUNT(DISTINCT t.fecha) AS dias
FROM hecho_partida_equipo h
JOIN dim_tiempo t ON t.id_tiempo = h.id_tiempo;
