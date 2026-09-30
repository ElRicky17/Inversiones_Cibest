import os
import pandas as pd
from sqlalchemy import create_engine

DB_USER = "postgres"
DB_PASS = "12345"
DB_HOST = "localhost"
DB_PORT = "5433"
DB_NAME = "analitica_inversiones"
DATA_DIR = "data"
engine = create_engine(f"postgresql+psycopg2://{DB_USER}:{DB_PASS}@{DB_HOST}:{DB_PORT}/{DB_NAME}")

files = [
    "cat_perfil_riesgo.csv",
    "catalogo_activos.csv",
    "catalogo_banca.csv",
    "historico_aba_macroactivos.csv",
    "historico_aba_usd_internacional.csv"
]
for file in files:
    file_path = os.path.join(DATA_DIR, file)

    if os.path.exists(file_path):
        table_name = os.path.splitext(file)[0]
        df = pd.read_csv(file_path)
        df.to_sql(table_name, engine, if_exists='replace', index=False)
        print(f"Tabla '{table_name}' cargada exitosamente ({len(df)} registros).")
    else:
        print(f"Archivo {file_path} no encontrado.")