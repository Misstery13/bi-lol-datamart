-- =====================================================================
-- ENTREGABLE 2 - MODELO DIMENSIONAL
-- Dataset: League of Legends 2024 Competitive Game dataset (Oracle's Elixir)
-- Motor: PostgreSQL 17 levantado con Docker (ver docker-compose.yml)
-- Ejecutar:
--   docker compose up -d
--   docker compose exec postgres psql -U bi_user -d bi_database -f /proyecto/01_modelo.sql
--
-- La base bi_database y el usuario bi_user los crea el propio contenedor,
-- por lo que no hace falta ejecutar CREATE DATABASE.
-- =====================================================================

DROP SCHEMA IF EXISTS dm CASCADE;
CREATE SCHEMA dm;
SET search_path TO dm;

-- =====================================================================
-- DIMENSIONES
-- =====================================================================

-- Dimension de tiempo: un registro por dia del calendario competitivo
CREATE TABLE dim_tiempo (
    id_tiempo      INTEGER      PRIMARY KEY,          -- formato AAAAMMDD
    fecha          DATE         NOT NULL UNIQUE,
    anio           SMALLINT     NOT NULL,
    trimestre      SMALLINT     NOT NULL,
    mes            SMALLINT     NOT NULL,
    nombre_mes     VARCHAR(15)  NOT NULL,
    dia            SMALLINT     NOT NULL,
    semana_anio    SMALLINT     NOT NULL,
    nombre_dia     VARCHAR(15)  NOT NULL,
    es_fin_semana  BOOLEAN      NOT NULL
);

-- Dimension de liga: liga + split + si es fase regular o playoffs
CREATE TABLE dim_liga (
    id_liga     SERIAL       PRIMARY KEY,
    liga        VARCHAR(40)  NOT NULL,
    split       VARCHAR(40)  NOT NULL DEFAULT 'Sin split',
    es_playoff  BOOLEAN      NOT NULL DEFAULT FALSE,
    CONSTRAINT uq_liga UNIQUE (liga, split, es_playoff)
);

-- Dimension de equipo
CREATE TABLE dim_equipo (
    id_equipo      SERIAL       PRIMARY KEY,
    nombre_equipo  VARCHAR(80)  NOT NULL UNIQUE,
    liga_principal VARCHAR(40)
);

-- Dimension de parche (version del juego)
CREATE TABLE dim_parche (
    id_parche     SERIAL       PRIMARY KEY,
    parche        VARCHAR(10)  NOT NULL UNIQUE,       -- ej. '14.10'
    temporada     SMALLINT     NOT NULL,
    nro_parche    SMALLINT     NOT NULL
);

-- Dimension de lado del mapa
CREATE TABLE dim_lado (
    id_lado  SMALLINT     PRIMARY KEY,
    lado     VARCHAR(10)  NOT NULL UNIQUE             -- 'Blue' / 'Red'
);

-- Dimension de campeon (alimenta el KPI de presencia en el draft)
CREATE TABLE dim_campeon (
    id_campeon  SERIAL       PRIMARY KEY,
    campeon     VARCHAR(40)  NOT NULL UNIQUE
);

-- =====================================================================
-- TABLA DE HECHOS PRINCIPAL
-- Granularidad: un registro representa la participacion de un equipo
--               en una partida competitiva (dos registros por partida).
-- =====================================================================
CREATE TABLE hecho_partida_equipo (
    id_hecho           BIGSERIAL    PRIMARY KEY,
    gameid             VARCHAR(50)  NOT NULL,
    id_tiempo          INTEGER      NOT NULL REFERENCES dim_tiempo (id_tiempo),
    id_liga            INTEGER      NOT NULL REFERENCES dim_liga   (id_liga),
    id_equipo          INTEGER      NOT NULL REFERENCES dim_equipo (id_equipo),
    id_equipo_rival    INTEGER          NULL REFERENCES dim_equipo (id_equipo),
    id_parche          INTEGER      NOT NULL REFERENCES dim_parche (id_parche),
    id_lado            SMALLINT     NOT NULL REFERENCES dim_lado   (id_lado),

    -- medidas
    victoria           SMALLINT     NOT NULL CHECK (victoria IN (0, 1)),
    duracion_seg       INTEGER      NOT NULL CHECK (duracion_seg > 0),
    kills              SMALLINT     NOT NULL DEFAULT 0,
    deaths             SMALLINT     NOT NULL DEFAULT 0,
    assists            SMALLINT     NOT NULL DEFAULT 0,
    oro_total          INTEGER      NOT NULL DEFAULT 0,
    oro_dif_15         INTEGER          NULL,          -- nulo si datacompleteness = partial
    dragones           SMALLINT     NOT NULL DEFAULT 0,
    barones            SMALLINT     NOT NULL DEFAULT 0,
    torres             SMALLINT     NOT NULL DEFAULT 0,
    dano_campeones     INTEGER      NOT NULL DEFAULT 0,
    vision_score       INTEGER          NULL,
    primera_sangre     SMALLINT     NOT NULL DEFAULT 0,
    primer_dragon      SMALLINT     NOT NULL DEFAULT 0,
    primera_torre      SMALLINT     NOT NULL DEFAULT 0,

    CONSTRAINT uq_partida_equipo UNIQUE (gameid, id_equipo)
);

-- =====================================================================
-- TABLA DE HECHOS SECUNDARIA (draft)
-- Granularidad: un registro representa un campeon seleccionado o baneado
--               por un equipo en una partida.
-- =====================================================================
CREATE TABLE hecho_draft (
    id_draft    BIGSERIAL    PRIMARY KEY,
    gameid      VARCHAR(50)  NOT NULL,
    id_tiempo   INTEGER      NOT NULL REFERENCES dim_tiempo  (id_tiempo),
    id_liga     INTEGER      NOT NULL REFERENCES dim_liga    (id_liga),
    id_equipo   INTEGER      NOT NULL REFERENCES dim_equipo  (id_equipo),
    id_parche   INTEGER      NOT NULL REFERENCES dim_parche  (id_parche),
    id_campeon  INTEGER      NOT NULL REFERENCES dim_campeon (id_campeon),
    tipo        VARCHAR(5)   NOT NULL CHECK (tipo IN ('pick', 'ban')),
    posicion    VARCHAR(10)      NULL,                 -- solo para picks
    victoria    SMALLINT         NULL CHECK (victoria IN (0, 1))
);

-- =====================================================================
-- INDICES PARA CONSULTAS DEL DASHBOARD
-- =====================================================================
CREATE INDEX idx_hpe_tiempo  ON hecho_partida_equipo (id_tiempo);
CREATE INDEX idx_hpe_liga    ON hecho_partida_equipo (id_liga);
CREATE INDEX idx_hpe_equipo  ON hecho_partida_equipo (id_equipo);
CREATE INDEX idx_hpe_parche  ON hecho_partida_equipo (id_parche);
CREATE INDEX idx_draft_camp  ON hecho_draft (id_campeon);
CREATE INDEX idx_draft_parche ON hecho_draft (id_parche);

-- Carga fija de la dimension de lado
INSERT INTO dim_lado (id_lado, lado) VALUES (1, 'Blue'), (2, 'Red');
