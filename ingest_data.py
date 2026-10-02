import os
import pandas as pd
from sqlalchemy import create_engine

DB_USER, DB_PASS = "postgres", "12345"
DB_HOST, DB_PORT, DB_NAME = "localhost", "5433", "analitica_inversiones"
DATA_DIR = "data"
engine = create_engine(f"postgresql+psycopg2://{DB_USER}:{DB_PASS}@{DB_HOST}:{DB_PORT}/{DB_NAME}")

files = [
    "cat_perfil_riesgo.csv",
    "catalogo_activos.csv",
    "catalogo_banca.csv",
    "historico_aba_macroactivos.csv",
    "historico_aba_usd_internacional.csv",
]
for file in files:
    path = os.path.join(DATA_DIR, file)
    if not os.path.exists(path):
        print(f"Archivo {path} no encontrado.")
        continue
    table = os.path.splitext(file)[0]
   
    df = pd.read_csv(path, dtype=str, keep_default_na=False, encoding="utf-8-sig")
    df.to_sql(table, engine, if_exists="replace", index=False, method="multi", chunksize=5000)
    print(f"Tabla '{table}' cargada ({len(df)} registros).")