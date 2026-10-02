"""
Modelo analítico de clientes: segmentación (K-Means) + Next Best Action (reglas).

Entradas : mv_portafolio_cop_ultimo y mv_portafolio_usd_ultimo (última fecha por cliente).
Salidas  : tabla `resultado_clientes` en PostgreSQL y resultados/clientes_segmentados.csv

Uso:
    python modelo_analitico.py                 # intenta traer TRM y volatilidad de mercado (yfinance)
    python modelo_analitico.py --sin-mercado   # sin internet: usa TRM por defecto
    python modelo_analitico.py --trm 3900      # fija la TRM manualmente
"""
import argparse
import os

import numpy as np
import pandas as pd
from sklearn.cluster import KMeans
from sklearn.metrics import silhouette_score
from sklearn.preprocessing import StandardScaler
from sqlalchemy import create_engine

DB_USER = os.getenv("DB_USER", "postgres")
DB_PASS = os.getenv("DB_PASS", "12345")
DB_HOST = os.getenv("DB_HOST", "127.0.0.1")
DB_PORT = os.getenv("DB_PORT", "5433")
DB_NAME = os.getenv("DB_NAME", "analitica_inversiones")

TRM_POR_DEFECTO = float(os.getenv("TRM_COP_USD", "3900"))   # aproximada: sustituir por la TRM del corte
ACTIVOS_LIQUIDEZ_COP = ["Renta Liquidez", "Fiducuenta"]


# ----------------------------------------------------------------------------
# 1. Datos de mercado (opcionales; si falla internet el modelo sigue funcionando)
# ----------------------------------------------------------------------------
def obtener_trm(fecha):
    try:
        import yfinance as yf
        h = yf.download("COP=X", start=fecha - pd.Timedelta(days=7), end=fecha + pd.Timedelta(days=3),
                        progress=False, auto_adjust=True)
        vals = np.ravel(h["Close"].to_numpy(dtype=float))
        vals = vals[~np.isnan(vals)]
        if len(vals):
            return float(vals[-1]), "yfinance (COP=X)"
    except Exception as e:  # noqa: BLE001
        print(f"   (sin TRM de mercado: {e})")
    return TRM_POR_DEFECTO, "valor por defecto"


def volatilidad_anual(simbolos, fecha):
    """Volatilidad anualizada a 1 año de cada símbolo. Devuelve {} si no hay internet."""
    try:
        import yfinance as yf
        tickers = sorted({s.replace(" ", "-") for s in simbolos})
        h = yf.download(tickers, start=fecha - pd.Timedelta(days=365), end=fecha,
                        progress=False, auto_adjust=True)["Close"]
        if isinstance(h, pd.Series):
            h = h.to_frame(tickers[0])
        r = np.log(h).diff().dropna(how="all")
        return (r.std() * np.sqrt(252)).dropna().to_dict()
    except Exception as e:  # noqa: BLE001
        print(f"   (sin volatilidad de mercado: {e})")
        return {}


# ----------------------------------------------------------------------------
# 2. Feature engineering (una fila por cliente)
# ----------------------------------------------------------------------------
def construir_features(df_cop, df_usd, trm, vol=None):
    cop, usd = df_cop.copy(), df_usd.copy()
    cop["saldo_cop"] = cop["saldo_cop"].astype(float)
    usd["saldo_usd"] = usd["saldo_usd"].astype(float)
    cid = "id_sistema_cliente"

    # --- Local (COP) ---
    pa = cop.groupby([cid, "nombre_activo"], as_index=False)["saldo_cop"].sum()
    pa = pa[pa["saldo_cop"] > 0].copy()
    pa["w"] = pa["saldo_cop"] / pa.groupby(cid)["saldo_cop"].transform("sum")
    top = pa.sort_values("saldo_cop", ascending=False).groupby(cid).first()
    g = pa.groupby(cid)
    f_cop = pd.DataFrame({
        "total_cop": g["saldo_cop"].sum(),
        "n_activos_cop": g["nombre_activo"].nunique(),
        "hhi_cop": g["w"].apply(lambda s: float((s ** 2).sum())),
        "top_activo_cop": top["nombre_activo"],
        "top_pct_cop": top["w"],
    })
    macro = cop.pivot_table(index=cid, columns="macroactivo", values="saldo_cop",
                            aggfunc="sum", fill_value=0)
    macro = macro.div(macro.sum(axis=1).replace(0, np.nan), axis=0)
    for col, nombre in [("Renta Fija", "pct_renta_fija"), ("Renta Variable", "pct_renta_variable"),
                        ("FICs", "pct_fics")]:
        f_cop[nombre] = (macro[col] if col in macro else 0.0)
        f_cop[nombre] = f_cop[nombre].reindex(f_cop.index).fillna(0.0) if hasattr(f_cop[nombre], "reindex") else 0.0
    liq = cop[cop["nombre_activo"].isin(ACTIVOS_LIQUIDEZ_COP)].groupby(cid)["saldo_cop"].sum()
    sin_cod = cop[cop["nombre_activo"] == "SIN CÓDIGO DE ACTIVO"].groupby(cid)["saldo_cop"].sum()
    f_cop["pct_liquidez_cop"] = (liq.reindex(f_cop.index).fillna(0) / f_cop["total_cop"]).fillna(0)
    f_cop["pct_sin_codigo"] = (sin_cod.reindex(f_cop.index).fillna(0) / f_cop["total_cop"]).fillna(0)
    attrs = cop.groupby(cid).agg(perfil_riesgo=("perfil_riesgo", "first"), banca=("banca", "first"),
                                 fecha_cop=("fecha_corte", "max"))
    f_cop = f_cop.join(attrs)

    # --- Internacional (USD) ---
    pu = usd.groupby([cid, "nombre_activo"], as_index=False)["saldo_usd"].sum()
    pu = pu[pu["saldo_usd"] > 0].copy()
    pu["w"] = pu["saldo_usd"] / pu.groupby(cid)["saldo_usd"].transform("sum")
    gu = pu.groupby(cid)
    f_usd = pd.DataFrame({
        "total_usd": gu["saldo_usd"].sum(),
        "n_activos_usd": gu["nombre_activo"].nunique(),
        "top_pct_usd": gu["w"].max(),
    })
    liq_u = usd[usd["tipo_activo"] == "Liquidez"].groupby(cid)["saldo_usd"].sum()
    f_usd["pct_liquidez_usd"] = (liq_u.reindex(f_usd.index).fillna(0) / f_usd["total_usd"]).fillna(0)
    f_usd["vol_usd_ponderada"] = np.nan
    if vol:
        sub = usd[(usd["tipo_activo"] == "Acción / ETF") & usd["simbolo"].notna()].copy()
        sub["vol"] = sub["simbolo"].str.replace(" ", "-").map(vol)
        sub = sub.dropna(subset=["vol"])
        if not sub.empty:
            num = (sub["vol"] * sub["saldo_usd"]).groupby(sub[cid]).sum()
            den = sub["saldo_usd"].groupby(sub[cid]).sum()
            f_usd["vol_usd_ponderada"] = (num / den).reindex(f_usd.index)

    # --- Consolidación ---
    df = f_cop.join(f_usd, how="outer")
    cero = ["total_cop", "n_activos_cop", "hhi_cop", "top_pct_cop", "pct_renta_fija", "pct_renta_variable",
            "pct_fics", "pct_liquidez_cop", "pct_sin_codigo", "total_usd", "n_activos_usd", "top_pct_usd",
            "pct_liquidez_usd"]
    df[cero] = df[cero].fillna(0.0)
    df["perfil_riesgo"] = df["perfil_riesgo"].fillna("NO REGISTRA")
    df["banca"] = df["banca"].fillna("NO REGISTRA")
    df["top_activo_cop"] = df["top_activo_cop"].fillna("")
    df = df.reset_index().rename(columns={"index": cid})
    df["id_aproximado"] = df[cid].astype(str).str.startswith("SCI-")
    df["trm_usada"] = trm
    df["total_usd_en_cop"] = df["total_usd"] * trm
    df["patrimonio_total_cop"] = df["total_cop"] + df["total_usd_en_cop"]
    df["pct_usd"] = np.where(df["patrimonio_total_cop"] > 0,
                             df["total_usd_en_cop"] / df["patrimonio_total_cop"], 0.0)
    df["n_activos_total"] = df["n_activos_cop"] + df["n_activos_usd"]
    return df[df["patrimonio_total_cop"] > 0].reset_index(drop=True)


# ----------------------------------------------------------------------------
# 3. Segmentación (K-Means con k elegido por silhouette)
# ----------------------------------------------------------------------------
def segmentar(df):
    df = df.copy()
    X = pd.DataFrame({
        "log_patrimonio": np.log10(df["patrimonio_total_cop"].clip(lower=1)),
        "pct_usd": df["pct_usd"],
        "hhi_cop": df["hhi_cop"],
        "pct_renta_variable": df["pct_renta_variable"],
        "pct_renta_fija": df["pct_renta_fija"],
    })
    n = len(df)
    if n < 6:
        df["cluster_id"], df["silhouette_k"], df["k"] = 0, np.nan, 1
    else:
        Xs = StandardScaler().fit_transform(X)
        mejor = (-1.0, 2, None)
        for k in range(2, min(6, n - 1) + 1):
            etiquetas = KMeans(n_clusters=k, random_state=42, n_init=10).fit_predict(Xs)
            s = silhouette_score(Xs, etiquetas)
            if s > mejor[0]:
                mejor = (s, k, etiquetas)
        df["cluster_id"], df["silhouette_k"], df["k"] = mejor[2], mejor[0], mejor[1]

    q25, q75 = df["patrimonio_total_cop"].quantile([.25, .75])
    nombres = {}
    for cid_, d in df.groupby("cluster_id"):
        tam = ("Patrimonio alto" if d["patrimonio_total_cop"].median() >= q75 else
               "Patrimonio bajo" if d["patrimonio_total_cop"].median() <= q25 else "Patrimonio medio")
        if d["pct_usd"].mean() > 0.20:
            estilo = "con exposición internacional"
        elif d["pct_renta_variable"].mean() > 0.50:
            estilo = "sesgo renta variable"
        elif d["pct_renta_fija"].mean() > 0.50:
            estilo = "sesgo renta fija"
        else:
            estilo = "balanceado / FICs"
        nombres[cid_] = f"C{cid_}: {tam}, {estilo}"
    df["segmento"] = df["cluster_id"].map(nombres)
    return df


# ----------------------------------------------------------------------------
# 4. Next Best Action (reglas transparentes y explicables)
# ----------------------------------------------------------------------------
def recomendar(df):
    df = df.copy()
    mediana = df["patrimonio_total_cop"].median()

    def reglas(r):
        out = []
        if r["perfil_riesgo"] == "SIN DEFINIR":
            out.append("Idoneidad: perfil de riesgo sin definir; aplicar test antes de ofertar productos.")
        if r["perfil_riesgo"] == "CONSERVADOR" and r["pct_renta_variable"] > 0.40:
            out.append(f"Idoneidad: perfil conservador con {r['pct_renta_variable']:.0%} en renta variable.")
        if r["perfil_riesgo"] == "AGRESIVO" and r["pct_renta_fija"] > 0.80:
            out.append(f"Oportunidad: perfil agresivo con {r['pct_renta_fija']:.0%} en renta fija; "
                       "evaluar mayor riesgo/retorno.")
        if r["top_pct_cop"] > 0.60 and r["n_activos_cop"] > 1:
            out.append(f"Concentración: {r['top_pct_cop']:.0%} en '{r['top_activo_cop']}'; diversificar.")
        if r["total_usd"] == 0 and r["patrimonio_total_cop"] >= mediana:
            out.append("Cobertura cambiaria: patrimonio sobre la mediana sin exposición USD; "
                       "ofrecer portafolio internacional.")
        if r["pct_liquidez_cop"] > 0.30:
            out.append(f"Liquidez ociosa: {r['pct_liquidez_cop']:.0%} en liquidez; "
                       "trasladar a renta fija o FIC de mayor plazo.")
        if r["total_usd"] > 0 and r["top_pct_usd"] > 0.40:
            out.append(f"Riesgo de emisor en USD: {r['top_pct_usd']:.0%} en una sola posición.")
        if pd.notna(r["vol_usd_ponderada"]) and r["vol_usd_ponderada"] > 0.30 and r["perfil_riesgo"] == "CONSERVADOR":
            out.append(f"Volatilidad USD ponderada de {r['vol_usd_ponderada']:.0%} alta para perfil conservador.")
        if r["pct_sin_codigo"] > 0.10:
            out.append(f"Calidad de datos: {r['pct_sin_codigo']:.0%} del portafolio sin código de activo.")
        return out or ["Portafolio balanceado: mantener estrategia y rebalancear semestralmente."]

    lista = df.apply(reglas, axis=1)
    df["n_alertas"] = lista.apply(lambda x: 0 if x[0].startswith("Portafolio balanceado") else len(x))
    df["siguiente_mejor_accion"] = lista.apply(" | ".join)
    return df


# ----------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sin-mercado", action="store_true", help="no consultar internet (TRM/volatilidad)")
    ap.add_argument("--trm", type=float, help="TRM COP/USD manual")
    args = ap.parse_args()

    engine = create_engine(f"postgresql+psycopg2://{DB_USER}:{DB_PASS}@{DB_HOST}:{DB_PORT}/{DB_NAME}")
    df_cop = pd.read_sql("SELECT * FROM mv_portafolio_cop_ultimo", engine)
    df_usd = pd.read_sql("SELECT * FROM mv_portafolio_usd_ultimo", engine)
    if df_cop.empty and df_usd.empty:
        raise SystemExit("Las vistas están vacías. ¿Ejecutaste run_sql.py (00, 01 y 05)?")

    fecha = pd.to_datetime(df_cop["fecha_corte"]).max() if not df_cop.empty else pd.Timestamp.today()
    print(f"1. Features (fecha de corte de referencia: {fecha.date()})")
    if args.trm:
        trm, fuente = args.trm, "manual"
    elif args.sin_mercado:
        trm, fuente = TRM_POR_DEFECTO, "valor por defecto"
    else:
        trm, fuente = obtener_trm(fecha)
    print(f"   TRM usada: {trm:,.2f} ({fuente})")
    vol = {}
    if not args.sin_mercado and not df_usd.empty:
        simbolos = df_usd.loc[df_usd["tipo_activo"] == "Acción / ETF", "simbolo"].dropna().unique()
        vol = volatilidad_anual(simbolos, fecha) if len(simbolos) else {}
        print(f"   Volatilidad de mercado obtenida para {len(vol)} símbolos")

    df = construir_features(df_cop, df_usd, trm, vol)
    print(f"   Clientes analizados: {len(df)}")

    print("2. Segmentación (K-Means, k por silhouette)")
    df = segmentar(df)
    print(f"   k elegido: {int(df['k'].iloc[0])} | silhouette: {df['silhouette_k'].iloc[0]:.3f}")

    print("3. Next Best Action")
    df = recomendar(df)

    os.makedirs("resultados", exist_ok=True)
    df.to_csv("resultados/clientes_segmentados.csv", index=False, encoding="utf-8-sig")
    df.to_sql("resultado_clientes", engine, if_exists="replace", index=False)
    print("   Guardado: tabla resultado_clientes y resultados/clientes_segmentados.csv\n")

    resumen = df.groupby("segmento").agg(clientes=("id_sistema_cliente", "count"),
                                         patrimonio_mediano=("patrimonio_total_cop", "median"),
                                         pct_usd_medio=("pct_usd", "mean"),
                                         alertas_promedio=("n_alertas", "mean")).round(2)
    print(resumen.to_string())
    print("\nTop 10 por patrimonio:")
    cols = ["id_sistema_cliente", "patrimonio_total_cop", "segmento", "siguiente_mejor_accion"]
    print(df.nlargest(10, "patrimonio_total_cop")[cols].to_string(index=False))


if __name__ == "__main__":
    main()