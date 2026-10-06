-- =====================================================================
-- ENTREGABLE 2 - VISTAS Y FUNCIONES PARA EL DASHBOARD
-- Cada objeto alimenta un componente concreto del mockup.
-- Ejecutar:
--   docker compose exec postgres psql -U bi_user -d bi_database -f /proyecto/05_vistas_funciones.sql
-- =====================================================================
SET search_path TO dm;

-- =====================================================================
-- VISTA BASE: aplana el hecho con sus dimensiones
-- =====================================================================
CREATE OR REPLACE VIEW vw_partidas AS
SELECT h.id_hecho,
       h.gameid,
       t.fecha, t.anio, t.mes, t.nombre_mes, t.semana_anio,
       l.liga, l.split, l.es_playoff,
       e.nombre_equipo              AS equipo,
       r.nombre_equipo              AS rival,
       p.parche,
       ld.lado,
       h.victoria, h.duracion_seg, h.kills, h.deaths, h.assists,
       h.oro_total, h.oro_dif_15, h.dragones, h.barones, h.torres,
       h.dano_campeones, h.vision_score,
       h.primera_sangre, h.primer_dragon, h.primera_torre
FROM hecho_partida_equipo h
JOIN dim_tiempo  t  ON t.id_tiempo = h.id_tiempo
JOIN dim_liga    l  ON l.id_liga   = h.id_liga
JOIN dim_equipo  e  ON e.id_equipo = h.id_equipo
LEFT JOIN dim_equipo r ON r.id_equipo = h.id_equipo_rival
JOIN dim_parche  p  ON p.id_parche = h.id_parche
JOIN dim_lado    ld ON ld.id_lado  = h.id_lado;

-- =====================================================================
-- KPI 1 - TASA DE VICTORIA POR EQUIPO
-- Alimenta: tarjeta KPI, tabla de detalle y grafico de barras
-- =====================================================================
CREATE OR REPLACE VIEW vw_kpi_equipo AS
SELECT equipo,
       liga,
       split,
       COUNT(*)                                   AS partidas,
       SUM(victoria)                              AS victorias,
       ROUND(100.0 * AVG(victoria), 2)            AS tasa_victoria,
       ROUND(AVG(oro_dif_15))                     AS oro_dif_15_prom,
       ROUND(AVG(duracion_seg) / 60.0, 1)         AS duracion_media_min,
       ROUND(AVG(dragones), 2)                    AS dragones_prom,
       ROUND(AVG(barones), 2)                     AS barones_prom
FROM vw_partidas
GROUP BY equipo, liga, split;

-- =====================================================================
-- KPI 2 - PRESENCIA DE CAMPEON EN EL DRAFT, POR PARCHE
-- Presencia = partidas en que el campeon fue elegido o baneado,
--             sobre el total de partidas de ese parche.
-- Alimenta: tabla de detalle y grafico de barras horizontales
-- =====================================================================
CREATE OR REPLACE VIEW vw_presencia_campeon AS
WITH partidas_parche AS (
    SELECT id_parche, COUNT(DISTINCT gameid) AS total_partidas
    FROM hecho_partida_equipo
    GROUP BY id_parche
)
SELECT p.parche,
       c.campeon,
       COUNT(DISTINCT d.gameid)                                      AS partidas_presente,
       pp.total_partidas,
       ROUND(100.0 * COUNT(DISTINCT d.gameid) / pp.total_partidas, 2) AS presencia_pct,
       COUNT(*) FILTER (WHERE d.tipo = 'pick')                       AS picks,
       COUNT(*) FILTER (WHERE d.tipo = 'ban')                        AS bans,
       ROUND(100.0 * AVG(d.victoria) FILTER (WHERE d.tipo = 'pick'), 2) AS win_rate
FROM hecho_draft d
JOIN dim_campeon c      ON c.id_campeon = d.id_campeon
JOIN dim_parche p       ON p.id_parche  = d.id_parche
JOIN partidas_parche pp ON pp.id_parche = d.id_parche
GROUP BY p.parche, c.campeon, pp.total_partidas;

-- =====================================================================
-- KPI 3 - VENTAJA TEMPRANA Y SU CONVERSION EN VICTORIA
-- Alimenta: tarjeta KPI y grafico de linea
-- =====================================================================
CREATE OR REPLACE VIEW vw_ventaja_temprana AS
SELECT liga,
       anio,
       mes,
       nombre_mes,
       COUNT(*)                                                       AS partidas,
       ROUND(AVG(oro_dif_15))                                         AS oro_dif_15_prom,
       ROUND(100.0 * AVG(victoria) FILTER (WHERE oro_dif_15 > 0), 2)  AS win_con_ventaja,
       ROUND(100.0 * AVG(victoria) FILTER (WHERE primer_dragon = 1), 2) AS win_primer_dragon,
       ROUND(100.0 * AVG(victoria) FILTER (WHERE primera_torre = 1), 2) AS win_primera_torre
FROM vw_partidas
WHERE oro_dif_15 IS NOT NULL
GROUP BY liga, anio, mes, nombre_mes;

-- =====================================================================
-- FUNCION 1 - Tasa de victoria filtrada por liga y rango de fechas
-- Alimenta la tarjeta KPI principal del dashboard
-- =====================================================================
CREATE OR REPLACE FUNCTION fn_tasa_victoria(
    p_liga        VARCHAR DEFAULT NULL,
    p_fecha_desde DATE    DEFAULT NULL,
    p_fecha_hasta DATE    DEFAULT NULL)
RETURNS TABLE (equipo VARCHAR, partidas BIGINT, victorias BIGINT, tasa_victoria NUMERIC)
LANGUAGE sql AS $$
    SELECT v.equipo,
           COUNT(*)                        AS partidas,
           SUM(v.victoria)::BIGINT         AS victorias,
           ROUND(100.0 * AVG(v.victoria), 2) AS tasa_victoria
    FROM vw_partidas v
    WHERE (p_liga        IS NULL OR v.liga  = p_liga)
      AND (p_fecha_desde IS NULL OR v.fecha >= p_fecha_desde)
      AND (p_fecha_hasta IS NULL OR v.fecha <= p_fecha_hasta)
    GROUP BY v.equipo
    ORDER BY tasa_victoria DESC;
$$;

-- Ejemplo:  SELECT * FROM fn_tasa_victoria('LCK', '2024-01-01', '2024-06-30');

-- =====================================================================
-- FUNCION 2 - Top de campeones por presencia en un parche
-- Alimenta el grafico de barras del metajuego
-- =====================================================================
CREATE OR REPLACE FUNCTION fn_top_campeones(
    p_parche VARCHAR,
    p_limite INTEGER DEFAULT 10)
RETURNS TABLE (campeon VARCHAR, presencia_pct NUMERIC, picks BIGINT,
               bans BIGINT, win_rate NUMERIC)
LANGUAGE sql AS $$
    SELECT c.campeon, c.presencia_pct, c.picks, c.bans, c.win_rate
    FROM vw_presencia_campeon c
    WHERE c.parche = p_parche
    ORDER BY c.presencia_pct DESC
    LIMIT p_limite;
$$;

-- Ejemplo:  SELECT * FROM fn_top_campeones('14.10', 15);

-- =====================================================================
-- FUNCION 3 - Evolucion mensual de un equipo
-- Alimenta el grafico de linea del detalle por equipo
-- =====================================================================
CREATE OR REPLACE FUNCTION fn_evolucion_equipo(p_equipo VARCHAR)
RETURNS TABLE (anio SMALLINT, mes SMALLINT, nombre_mes VARCHAR,
               partidas BIGINT, tasa_victoria NUMERIC, oro_dif_15_prom NUMERIC)
LANGUAGE sql AS $$
    SELECT v.anio, v.mes, v.nombre_mes,
           COUNT(*)                          AS partidas,
           ROUND(100.0 * AVG(v.victoria), 2) AS tasa_victoria,
           ROUND(AVG(v.oro_dif_15))          AS oro_dif_15_prom
    FROM vw_partidas v
    WHERE v.equipo = p_equipo
    GROUP BY v.anio, v.mes, v.nombre_mes
    ORDER BY v.anio, v.mes;
$$;

-- Ejemplo:  SELECT * FROM fn_evolucion_equipo('T1');
