"""
ENTREGABLE 3 - DASHBOARD DE BUSINESS INTELLIGENCE
Aplicacion Streamlit conectada al Data Mart dm en PostgreSQL.
Todos los datos se obtienen de las vistas y funciones de 05_vistas_funciones.sql;
la aplicacion no lee el dataset original.

Uso:  streamlit run app/app.py
"""

import os

import pandas as pd
import psycopg2
import streamlit as st

st.set_page_config(page_title="LoL Competitivo 2024 - BI", page_icon="📊", layout="wide")


# --------------------------------------------------------------- CONEXION
# psycopg2 devuelve NUMERIC como Decimal, que pandas guarda como texto (object) y los
# graficos tratan como categoria. Se convierte a float al leerlo.
psycopg2.extensions.register_type(psycopg2.extensions.new_type(
    psycopg2.extensions.DECIMAL.values, "NUMERIC_A_FLOAT",
    lambda valor, cur: float(valor) if valor is not None else None))

# Los valores por defecto son los de docker-compose.yml; se pueden cambiar
# con variables de entorno sin tocar el codigo.
@st.cache_resource
def conexion():
    return psycopg2.connect(
        host=os.getenv("PGHOST", "localhost"),
        port=os.getenv("PGPORT", "5433"),
        dbname=os.getenv("PGDATABASE", "bi_database"),
        user=os.getenv("PGUSER", "bi_user"),
        password=os.getenv("PGPASSWORD", "bi_password"),
        options="-c search_path=dm",
    )


@st.cache_data(ttl=600)
def consulta(sql, params=None):
    """Ejecuta una consulta parametrizada y devuelve un DataFrame."""
    with conexion().cursor() as cur:
        cur.execute(sql, params)
        columnas = [c.name for c in cur.description]
        return pd.DataFrame(cur.fetchall(), columns=columnas)


# ---------------------------------------------------------------- FILTROS
# Las opciones de cada filtro salen de las dimensiones.
ligas = consulta("SELECT DISTINCT liga FROM dim_liga ORDER BY liga")["liga"].tolist()
splits = consulta("SELECT DISTINCT split FROM dim_liga ORDER BY split")["split"].tolist()
parches = consulta("SELECT parche FROM dim_parche ORDER BY temporada, nro_parche")["parche"].tolist()
rango = consulta("SELECT MIN(fecha) AS desde, MAX(fecha) AS hasta FROM dim_tiempo").iloc[0]

st.sidebar.header("Filtros")
f_ligas = st.sidebar.multiselect("Liga", ligas, default=["LCK", "LPL", "LEC", "LCS"],
                                 help="Vacío = todas las ligas")
f_splits = st.sidebar.multiselect("Split", splits, help="Vacío = todos los splits")
f_fechas = st.sidebar.date_input("Rango de fechas", (rango.desde, rango.hasta),
                                 min_value=rango.desde, max_value=rango.hasta)
f_parches = st.sidebar.multiselect("Parche", parches, help="Vacío = todos los parches")
min_partidas = st.sidebar.slider("Mínimo de partidas por equipo", 1, 20, 5)

# date_input devuelve una sola fecha mientras el usuario elige el rango
desde, hasta = f_fechas if len(f_fechas) == 2 else (f_fechas[0], f_fechas[0])

# Lista vacia = sin filtro. Se pasa como parametro, nunca concatenado al SQL.
P = {"ligas": f_ligas or None, "splits": f_splits or None,
     "parches": f_parches or None, "desde": desde, "hasta": hasta,
     "min_partidas": min_partidas}
WHERE = """
    WHERE (%(ligas)s::text[]   IS NULL OR liga   = ANY(%(ligas)s))
      AND (%(splits)s::text[]  IS NULL OR split  = ANY(%(splits)s))
      AND (%(parches)s::text[] IS NULL OR parche = ANY(%(parches)s))
      AND fecha BETWEEN %(desde)s AND %(hasta)s
"""

# ------------------------------------------------------------- CONSULTAS
equipos = consulta(f"""
    SELECT equipo, liga, COUNT(*) AS partidas, SUM(victoria) AS victorias,
           ROUND(100.0 * AVG(victoria), 1) AS tasa_victoria,
           ROUND(AVG(oro_dif_15)) AS oro_dif_15_prom,
           ROUND(AVG(duracion_seg) / 60.0, 1) AS duracion_min
    FROM vw_partidas {WHERE}
    GROUP BY equipo, liga
    HAVING COUNT(*) >= %(min_partidas)s
    ORDER BY tasa_victoria DESC, partidas DESC
""", P)

total_partidas = consulta(f"SELECT COUNT(DISTINCT gameid) AS n FROM vw_partidas {WHERE}", P).n[0]

ventaja = consulta(f"""
    SELECT COUNT(*) AS partidas,
           ROUND(100.0 * AVG(victoria) FILTER (WHERE oro_dif_15 > 0), 1) AS win_con_ventaja,
           ROUND(100.0 * AVG(victoria) FILTER (WHERE primer_dragon = 1), 1) AS win_primer_dragon,
           ROUND(100.0 * AVG(victoria) FILTER (WHERE primera_torre = 1), 1) AS win_primera_torre
    FROM vw_partidas {WHERE} AND oro_dif_15 IS NOT NULL
""", P).iloc[0]

semanal = consulta(f"""
    SELECT date_trunc('week', fecha)::date AS semana,
           ROUND(100.0 * AVG(victoria) FILTER (WHERE oro_dif_15 > 0), 1) AS "Con ventaja de oro al 15",
           ROUND(100.0 * AVG(victoria) FILTER (WHERE primera_torre = 1), 1) AS "Con primera torre",
           ROUND(100.0 * AVG(victoria) FILTER (WHERE primer_dragon = 1), 1) AS "Con primer dragón"
    FROM vw_partidas {WHERE} AND oro_dif_15 IS NOT NULL
    GROUP BY 1 ORDER BY 1
""", P)

# Presencia = partidas con el campeon elegido o baneado / partidas del filtro
campeones = consulta(f"""
    WITH d AS (SELECT * FROM vw_draft {WHERE}),
         total AS (SELECT COUNT(DISTINCT gameid) AS n FROM d)
    SELECT campeon,
           ROUND(100.0 * COUNT(DISTINCT gameid) / NULLIF((SELECT n FROM total), 0), 1) AS presencia_pct,
           COUNT(*) FILTER (WHERE tipo = 'pick') AS picks,
           COUNT(*) FILTER (WHERE tipo = 'ban')  AS bans,
           ROUND(100.0 * AVG(victoria) FILTER (WHERE tipo = 'pick'), 1) AS win_rate,
           MODE() WITHIN GROUP (ORDER BY posicion) AS posicion_habitual
    FROM d
    GROUP BY campeon
    ORDER BY presencia_pct DESC
""", P)

# ------------------------------------------------------------- ENCABEZADO
st.title("Rendimiento competitivo · League of Legends 2024")
st.caption(f"Data Mart `dm` en PostgreSQL · {total_partidas:,} partidas en el filtro · "
           f"{desde:%d/%m/%Y} – {hasta:%d/%m/%Y}")

if equipos.empty:
    st.warning("No hay partidas para los filtros elegidos. Amplía el rango o quita filtros.")
    st.stop()

general, metajuego, equipo_tab, detalle = st.tabs(
    ["Vista general", "Metajuego", "Equipo", "Detalle de partidas"])

# ------------------------------------------------------- VISTA GENERAL
with general:
    mejor = equipos.iloc[0]
    top_camp = campeones.iloc[0] if not campeones.empty else None
    k1, k2, k3 = st.columns(3)
    k1.metric("Mejor tasa de victoria", f"{mejor.tasa_victoria:.1f} %",
              help="vw_partidas: victorias / partidas, por equipo")
    k1.caption(f"{mejor.equipo} · {mejor.partidas} partidas")
    k2.metric("Victorias con ventaja de oro al min 15",
              f"{ventaja.win_con_ventaja:.1f} %" if pd.notna(ventaja.win_con_ventaja) else "s/d",
              help="vw_partidas: excluye ligas con datos parciales (oro_dif_15 nulo)")
    k2.caption(f"Sobre {int(ventaja.partidas):,} registros con dato de oro al min 15")
    k3.metric("Presencia del campeón más contestado",
              f"{top_camp.presencia_pct:.1f} %" if top_camp is not None else "s/d",
              help="vw_draft: partidas con pick o ban / partidas del filtro")
    k3.caption(top_camp.campeon if top_camp is not None else "")

    c1, c2 = st.columns(2)
    with c1:
        st.subheader("¿Qué equipos rinden mejor?")
        st.caption(f"Tasa de victoria (%) · top 15 con al menos {min_partidas} partidas")
        st.bar_chart(equipos.head(15), x="equipo", y="tasa_victoria",
                     x_label="", y_label="Tasa de victoria (%)", sort="-tasa_victoria")
    with c2:
        st.subheader("¿Cuánto pesa la ventaja temprana?")
        st.caption("Tasa de victoria (%) por semana según el objetivo temprano conseguido")
        if semanal.empty:
            st.info("Las ligas filtradas no publican oro al minuto 15.")
        else:
            st.line_chart(semanal, x="semana", x_label="", y_label="Tasa de victoria (%)")

# ---------------------------------------------------------- METAJUEGO
with metajuego:
    st.subheader("¿Qué campeones dominan el metajuego?")
    n = st.slider("Campeones a mostrar", 5, 30, 15)
    st.caption("Picks y bans de los campeones con mayor presencia, ordenados de mayor a menor")
    st.bar_chart(campeones.head(n), x="campeon", y=["picks", "bans"], horizontal=True,
                 x_label="", y_label="Picks y bans", stack=True, sort="-presencia_pct")
    st.dataframe(campeones, hide_index=True, use_container_width=True, column_config={
        "campeon": "Campeón", "presencia_pct": st.column_config.ProgressColumn(
            "Presencia", format="%.1f %%", min_value=0, max_value=100),
        "picks": "Picks", "bans": "Bans",
        "win_rate": st.column_config.NumberColumn("Win rate", format="%.1f %%"),
        "posicion_habitual": "Posición habitual"})

# ------------------------------------------------------------- EQUIPO
with equipo_tab:
    nombre = st.selectbox("Equipo", equipos["equipo"])
    fila = equipos[equipos["equipo"] == nombre].iloc[0]
    e1, e2, e3, e4 = st.columns(4)
    e1.metric("Partidas", int(fila.partidas))
    e2.metric("Tasa de victoria", f"{fila.tasa_victoria:.1f} %")
    e3.metric("Oro al min 15 (prom.)",
              f"{fila.oro_dif_15_prom:+,.0f}" if pd.notna(fila.oro_dif_15_prom) else "s/d")
    e4.metric("Duración media", f"{fila.duracion_min} min")

    st.caption("Evolución mensual · fn_evolucion_equipo()")
    evolucion = consulta("SELECT * FROM fn_evolucion_equipo(%s)", (nombre,))
    st.dataframe(evolucion, hide_index=True, use_container_width=True)

    st.caption("Campeones más usados por el equipo en el filtro")
    st.dataframe(consulta(f"""
        SELECT campeon, posicion, COUNT(*) AS partidas,
               ROUND(100.0 * AVG(victoria), 1) AS win_rate
        FROM vw_draft {WHERE} AND tipo = 'pick' AND equipo = %(equipo)s
        GROUP BY campeon, posicion ORDER BY partidas DESC LIMIT 10
    """, {**P, "equipo": nombre}), hide_index=True, use_container_width=True)

# ---------------------------------------------------- DETALLE DE PARTIDAS
with detalle:
    st.subheader("Detalle de partidas")
    partidas = consulta(f"""
        SELECT fecha, liga, split, parche, equipo, rival, lado,
               CASE WHEN victoria = 1 THEN 'Victoria' ELSE 'Derrota' END AS resultado,
               ROUND(duracion_seg / 60.0, 1) AS duracion_min,
               kills, deaths, assists, oro_dif_15, dragones, barones, torres
        FROM vw_partidas {WHERE}
        ORDER BY fecha DESC, gameid, lado
    """, P)
    st.caption(f"{len(partidas):,} registros (una fila = un equipo en una partida)")
    st.dataframe(partidas, hide_index=True, use_container_width=True)
    st.download_button("Descargar CSV", partidas.to_csv(index=False).encode("utf-8"),
                       "partidas_filtradas.csv", "text/csv")
