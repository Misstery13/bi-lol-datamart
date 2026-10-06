"""
ENTREGABLE 2 - LIMPIEZA Y TRANSFORMACION
Lee el Excel descargado de Kaggle (Oracle's Elixir 2024) y genera tres archivos
limpios que luego se cargan en PostgreSQL mediante \\copy.

Requisitos:  pip install pandas openpyxl
Uso:         python 02_limpieza.py

Salidas:
    salida/stg_partidas.csv   -> filas de equipo (una por equipo y partida)
    salida/stg_draft.csv      -> picks y bans por equipo y partida
    salida/stg_tiempo.csv     -> dimension de tiempo generada del calendario
"""

import os
import pandas as pd

ARCHIVO = "2024_LoL_esports_match_data_from_OraclesElixir.xlsx"
SALIDA = "salida"
MESES = ["enero", "febrero", "marzo", "abril", "mayo", "junio",
         "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre"]
DIAS = ["lunes", "martes", "miercoles", "jueves", "viernes", "sabado", "domingo"]

os.makedirs(SALIDA, exist_ok=True)

# ---------------------------------------------------------------- 1. LECTURA
df = pd.read_excel(ARCHIVO)
print(f"Filas originales: {len(df):,}  |  Columnas: {df.shape[1]}")

# ------------------------------------------------- 2. TIPOS DE DATOS CORRECTOS
# date llega como texto -> se convierte a fecha y hora
df["date"] = pd.to_datetime(df["date"], errors="coerce")
# patch llega como numero y pierde el formato -> se fuerza a texto
df["patch"] = df["patch"].astype(str)
# result llega como 0/1 entero -> se conserva como entero para poder promediar
df["result"] = pd.to_numeric(df["result"], errors="coerce")

# ------------------------------------------- 3. SEPARAR GRANULARIDAD MEZCLADA
# Cada partida trae 12 filas: 10 de jugador y 2 de resumen por equipo.
equipos = df[df["position"] == "team"].copy()
jugadores = df[df["position"] != "team"].copy()
print(f"Filas de equipo: {len(equipos):,}  |  Filas de jugador: {len(jugadores):,}")

# ----------------------------------------------------- 4. LIMPIEZA DE FILTROS
# Partidas sin fecha o sin resultado no sirven para el analisis
equipos = equipos.dropna(subset=["date", "result", "gameid", "teamname"])

# Remakes: partidas abandonadas en los primeros minutos (valores atipicos)
MIN_DURACION = 900  # 15 minutos en segundos
remakes = (equipos["gamelength"] < MIN_DURACION).sum()
equipos = equipos[equipos["gamelength"] >= MIN_DURACION]
print(f"Remakes descartados (menos de 15 min): {remakes}")

# Duplicados exactos por partida y equipo
antes = len(equipos)
equipos = equipos.drop_duplicates(subset=["gameid", "teamname"])
print(f"Duplicados eliminados: {antes - len(equipos)}")

# ------------------------------------------- 5. NORMALIZAR TEXTO Y CATEGORIAS
equipos["split"] = equipos["split"].fillna("Sin split")
for col in ["league", "split", "teamname", "side"]:
    equipos[col] = equipos[col].astype(str).str.strip()

equipos["split"] = equipos["split"].replace({"nan": "Sin split", "": "Sin split"})
equipos["playoffs"] = pd.to_numeric(equipos["playoffs"], errors="coerce").fillna(0).astype(int)
equipos["side"] = equipos["side"].str.capitalize()

# ------------------------------------------------------- 6. EQUIPO RIVAL
# Se arma con el otro equipo de la misma partida
rival = equipos[["gameid", "teamname"]].copy()
rival = rival.merge(rival, on="gameid", suffixes=("", "_rival"))
rival = rival[rival["teamname"] != rival["teamname_rival"]]
equipos = equipos.merge(rival, on=["gameid", "teamname"], how="left")

# --------------------------------------------- 7. SELECCION DE COLUMNAS UTILES
# Se descartan columnas sin aporte analitico (url, identificadores internos)
cols_partida = {
    "gameid": "gameid", "date": "fecha_hora", "league": "liga", "split": "split",
    "playoffs": "es_playoff", "patch": "parche", "teamname": "equipo",
    "teamname_rival": "equipo_rival", "side": "lado", "result": "victoria",
    "gamelength": "duracion_seg", "kills": "kills", "deaths": "deaths",
    "assists": "assists", "totalgold": "oro_total", "golddiffat15": "oro_dif_15",
    "dragons": "dragones", "barons": "barones", "towers": "torres",
    "damagetochampions": "dano_campeones", "visionscore": "vision_score",
    "firstblood": "primera_sangre", "firstdragon": "primer_dragon",
    "firsttower": "primera_torre",
}
partidas = equipos[list(cols_partida)].rename(columns=cols_partida)

# Las columnas de objetivos llegan con nulos cuando la liga no publica el dato
for col in ["dragones", "barones", "torres", "primera_sangre",
            "primer_dragon", "primera_torre", "dano_campeones"]:
    partidas[col] = pd.to_numeric(partidas[col], errors="coerce").fillna(0).astype(int)

# oro_dif_15 se deja nulo a proposito: indica datacompleteness = partial
nulos_oro = partidas["oro_dif_15"].isna().sum()
print(f"Registros sin oro_dif_15 (datos parciales): {nulos_oro:,} "
      f"({nulos_oro / len(partidas):.1%})")

# Entero con nulos (Int64): sin esto pandas escribe 1729.0 y PostgreSQL lo rechaza
for col in partidas.select_dtypes("number").columns:
    partidas[col] = partidas[col].astype("Int64")

partidas["fecha"] = partidas["fecha_hora"].dt.date
partidas = partidas.drop(columns=["fecha_hora"])

# ----------------------------------------------------------- 8. DRAFT
# Picks: vienen de las filas de jugador
picks = jugadores.dropna(subset=["champion", "teamname", "gameid"])[
    ["gameid", "teamname", "champion", "position", "result"]].copy()
picks["tipo"] = "pick"
picks = picks.rename(columns={"teamname": "equipo", "champion": "campeon",
                              "position": "posicion", "result": "victoria"})

# Bans: vienen de las filas de equipo, en cinco columnas separadas
bans = equipos.melt(
    id_vars=["gameid", "teamname", "result"],
    value_vars=["ban1", "ban2", "ban3", "ban4", "ban5"],
    value_name="campeon").dropna(subset=["campeon"])
bans["tipo"] = "ban"
bans["posicion"] = None
bans = bans.rename(columns={"teamname": "equipo", "result": "victoria"})
bans = bans[["gameid", "equipo", "campeon", "posicion", "victoria", "tipo"]]

draft = pd.concat([picks, bans], ignore_index=True)
draft = draft.merge(partidas[["gameid", "equipo", "fecha", "liga", "split",
                              "es_playoff", "parche"]],
                    on=["gameid", "equipo"], how="inner")
draft["campeon"] = draft["campeon"].astype(str).str.strip()

# ------------------------------------------------------- 9. DIMENSION TIEMPO
fechas = pd.to_datetime(sorted(partidas["fecha"].unique()))
tiempo = pd.DataFrame({"fecha": fechas})
tiempo["id_tiempo"] = tiempo["fecha"].dt.strftime("%Y%m%d").astype(int)
tiempo["anio"] = tiempo["fecha"].dt.year
tiempo["trimestre"] = tiempo["fecha"].dt.quarter
tiempo["mes"] = tiempo["fecha"].dt.month
tiempo["nombre_mes"] = tiempo["mes"].apply(lambda m: MESES[m - 1])
tiempo["dia"] = tiempo["fecha"].dt.day
tiempo["semana_anio"] = tiempo["fecha"].dt.isocalendar().week.astype(int)
tiempo["nombre_dia"] = tiempo["fecha"].dt.weekday.apply(lambda d: DIAS[d])
tiempo["es_fin_semana"] = tiempo["fecha"].dt.weekday >= 5
tiempo = tiempo[["id_tiempo", "fecha", "anio", "trimestre", "mes", "nombre_mes",
                 "dia", "semana_anio", "nombre_dia", "es_fin_semana"]]

# ---------------------------------------------------------- 10. EXPORTACION
partidas.to_csv(f"{SALIDA}/stg_partidas.csv", index=False)
draft.to_csv(f"{SALIDA}/stg_draft.csv", index=False)
tiempo.to_csv(f"{SALIDA}/stg_tiempo.csv", index=False)

print("\n--- RESUMEN ---")
print(f"Partidas (equipo-partida): {len(partidas):,}")
print(f"Partidas unicas:           {partidas['gameid'].nunique():,}")
print(f"Registros de draft:        {len(draft):,}")
print(f"Dias en dim_tiempo:        {len(tiempo):,}")
print(f"Rango de fechas:           {partidas['fecha'].min()} a {partidas['fecha'].max()}")
print(f"Archivos generados en ./{SALIDA}/")
