-- =====================================================================
-- ENTREGABLE 2 - CARGA DE DATOS
-- Ejecutar desde psql (no desde pgAdmin, porque usa \copy):
--   docker compose exec postgres psql -U bi_user -d bi_database -f /proyecto/03_carga.sql
--
-- Los CSV los genera 02_limpieza.py en ./salida, carpeta que el contenedor ve
-- como /proyecto/salida gracias al volumen declarado en docker-compose.yml.
-- Si en lugar de Docker se usa un PostgreSQL instalado en el sistema, basta con
-- cambiar las tres rutas de abajo de '/proyecto/salida/...' a 'salida/...'.
-- =====================================================================

SET search_path TO dm;

-- ---------------------------------------------------------- STAGING
DROP TABLE IF EXISTS stg_partidas, stg_draft, stg_tiempo;

CREATE TABLE stg_partidas (
    gameid          VARCHAR(50),
    liga            VARCHAR(40),
    split           VARCHAR(40),
    es_playoff      INTEGER,
    parche          VARCHAR(10),
    equipo          VARCHAR(80),
    equipo_rival    VARCHAR(80),
    lado            VARCHAR(10),
    victoria        INTEGER,
    duracion_seg    INTEGER,
    kills           INTEGER,
    deaths          INTEGER,
    assists         INTEGER,
    oro_total       INTEGER,
    oro_dif_15      INTEGER,
    dragones        INTEGER,
    barones         INTEGER,
    torres          INTEGER,
    dano_campeones  INTEGER,
    vision_score    INTEGER,
    primera_sangre  INTEGER,
    primer_dragon   INTEGER,
    primera_torre   INTEGER,
    fecha           DATE
);

CREATE TABLE stg_draft (
    gameid      VARCHAR(50),
    equipo      VARCHAR(80),
    campeon     VARCHAR(40),
    posicion    VARCHAR(10),
    victoria    INTEGER,
    tipo        VARCHAR(5),
    fecha       DATE,
    liga        VARCHAR(40),
    split       VARCHAR(40),
    es_playoff  INTEGER,
    parche      VARCHAR(10)
);

CREATE TABLE stg_tiempo (
    id_tiempo      INTEGER,
    fecha          DATE,
    anio           INTEGER,
    trimestre      INTEGER,
    mes            INTEGER,
    nombre_mes     VARCHAR(15),
    dia            INTEGER,
    semana_anio    INTEGER,
    nombre_dia     VARCHAR(15),
    es_fin_semana  BOOLEAN
);

\copy stg_partidas FROM '/proyecto/salida/stg_partidas.csv' WITH (FORMAT csv, HEADER true);
\copy stg_draft    FROM '/proyecto/salida/stg_draft.csv'    WITH (FORMAT csv, HEADER true);
\copy stg_tiempo   FROM '/proyecto/salida/stg_tiempo.csv'   WITH (FORMAT csv, HEADER true);

-- ------------------------------------------------------- DIMENSIONES
INSERT INTO dim_tiempo
SELECT id_tiempo, fecha, anio, trimestre, mes, nombre_mes,
       dia, semana_anio, nombre_dia, es_fin_semana
FROM stg_tiempo
ON CONFLICT (id_tiempo) DO NOTHING;

INSERT INTO dim_liga (liga, split, es_playoff)
SELECT DISTINCT liga, COALESCE(split, 'Sin split'), (es_playoff = 1)
FROM stg_partidas
ON CONFLICT (liga, split, es_playoff) DO NOTHING;

-- La liga principal de un equipo es aquella donde disputo mas partidas
INSERT INTO dim_equipo (nombre_equipo, liga_principal)
SELECT equipo, liga FROM (
    SELECT equipo, liga,
           ROW_NUMBER() OVER (PARTITION BY equipo ORDER BY COUNT(*) DESC) AS rn
    FROM stg_partidas
    GROUP BY equipo, liga
) t
WHERE rn = 1
ON CONFLICT (nombre_equipo) DO NOTHING;

INSERT INTO dim_parche (parche, temporada, nro_parche)
SELECT DISTINCT parche,
       SPLIT_PART(parche, '.', 1)::SMALLINT,
       SPLIT_PART(parche, '.', 2)::SMALLINT
FROM stg_partidas
WHERE parche ~ '^[0-9]+\.[0-9]+$'
ON CONFLICT (parche) DO NOTHING;

INSERT INTO dim_campeon (campeon)
SELECT DISTINCT campeon FROM stg_draft WHERE campeon IS NOT NULL
ON CONFLICT (campeon) DO NOTHING;

-- ------------------------------------------------------- TABLA DE HECHOS
INSERT INTO hecho_partida_equipo (
    gameid, id_tiempo, id_liga, id_equipo, id_equipo_rival, id_parche, id_lado,
    victoria, duracion_seg, kills, deaths, assists, oro_total, oro_dif_15,
    dragones, barones, torres, dano_campeones, vision_score,
    primera_sangre, primer_dragon, primera_torre)
SELECT s.gameid,
       t.id_tiempo,
       l.id_liga,
       e.id_equipo,
       r.id_equipo,
       pa.id_parche,
       ld.id_lado,
       s.victoria, s.duracion_seg, s.kills, s.deaths, s.assists,
       s.oro_total, s.oro_dif_15, s.dragones, s.barones, s.torres,
       s.dano_campeones, s.vision_score,
       s.primera_sangre, s.primer_dragon, s.primera_torre
FROM stg_partidas s
JOIN dim_tiempo t  ON t.fecha = s.fecha
JOIN dim_liga   l  ON l.liga = s.liga
                  AND l.split = COALESCE(s.split, 'Sin split')
                  AND l.es_playoff = (s.es_playoff = 1)
JOIN dim_equipo e  ON e.nombre_equipo = s.equipo
LEFT JOIN dim_equipo r ON r.nombre_equipo = s.equipo_rival
JOIN dim_parche pa ON pa.parche = s.parche
JOIN dim_lado  ld  ON ld.lado = s.lado
ON CONFLICT (gameid, id_equipo) DO NOTHING;

INSERT INTO hecho_draft (
    gameid, id_tiempo, id_liga, id_equipo, id_parche, id_campeon,
    tipo, posicion, victoria)
SELECT d.gameid, t.id_tiempo, l.id_liga, e.id_equipo, pa.id_parche, ca.id_campeon,
       d.tipo, d.posicion, d.victoria
FROM stg_draft d
JOIN dim_tiempo  t  ON t.fecha = d.fecha
JOIN dim_liga    l  ON l.liga = d.liga
                   AND l.split = COALESCE(d.split, 'Sin split')
                   AND l.es_playoff = (d.es_playoff = 1)
JOIN dim_equipo  e  ON e.nombre_equipo = d.equipo
JOIN dim_parche  pa ON pa.parche = d.parche
JOIN dim_campeon ca ON ca.campeon = d.campeon;

-- Las tablas de staging ya no son necesarias
-- DROP TABLE stg_partidas, stg_draft, stg_tiempo;
