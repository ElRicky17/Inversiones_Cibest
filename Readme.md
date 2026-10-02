# Analítica de Inversiones — Valores Bancolombia

Herramienta analítica para gerentes comerciales y equipos estructuradores: consolida en PostgreSQL
las fuentes de portafolios locales (COP) e internacionales (USD), limpia los datos **en SQL**,
los visualiza por cliente en una app Django y los segmenta con un modelo que sugiere la
siguiente mejor acción comercial.

```
CSV (data/) ──Python──► Tablas RAW ──SQL──► Vistas limpias ──► Vistas materializadas ──► Django (Plotly)
                      (todo texto)   00 + 01   (limpieza, catálogos)      05                  └──► modelo_analitico.py
```

## Requisitos

- Docker Desktop / Docker Engine
- Python 3.12 o superior
- Los 5 archivos `.csv` suministrados (no se incluyen en el repositorio)
- Internet (opcional) para que el modelo consulte la TRM y la volatilidad en Yahoo Finance (`yfinance`)

## Estructura del proyecto

```text
Inversiones_Cibest/
├── data/                       # CSV de entrada (ignorados por git: copiarlos aquí)
├── config/                     # Configuración Django (settings.py, urls.py, ...)
├── portafolio/                 # App Django
│   ├── models.py               # Modelos sobre las vistas materializadas (managed = False)
│   ├── views.py                # Dashboard: selector de cliente + datos para los gráficos
│   └── templates/portafolio/dashboard.html   # Plotly: dona COP por macroactivo, barras USD
├── 00_funciones.sql            # Funciones de limpieza (texto, números, fechas, IDs)
├── 01_vistas.sql               # Catálogos limpios + vistas COP/USD (histórica y "último")
├── 02_diagnostico.sql          # (opcional) Cuantifica los problemas de calidad de datos
├── 03_verificacion.sql         # (opcional) Cuadres de saldos y pruebas puntuales
├── 04_investigacion.sql        # (opcional) IDs científicos, duplicados, typos de ID
├── 05_materializar.sql         # Vistas materializadas indexadas (consulta instantánea)
├── ingest_data.py              # Carga CSV → tablas RAW (todo como texto)
├── run_sql.py                  # Ejecuta los .sql en orden (sin necesitar psql)
├── modelo_analitico.py         # Segmentación K-Means + Next Best Action
├── resultados/                 # Salida del modelo (ignorada por git)
├── docker-compose.yml          # PostgreSQL
├── manage.py
├── requirements.txt
└── README.md
```

## Ejecución paso a paso

### 1. Base de datos
```bash
docker compose up -d
```
PostgreSQL queda en `127.0.0.1:5433` (usuario `postgres`, clave `12345`, base `analitica_inversiones`).

### 2. Entorno Python
```bash
python -m venv venv
.\venv\Scripts\Activate.ps1        # Windows PowerShell
source venv/bin/activate           # Linux / macOS
pip install -r requirements.txt
```
`requirements.txt` debe incluir, entre otras, `pandas`, `numpy`, `scikit-learn`, `sqlalchemy`, `psycopg2-binary`
y `yfinance` (esta última solo se usa si se consultan datos de mercado).

### 3. Ingesta (capa RAW)
Copiar los 5 CSV en `data/` y ejecutar:
```bash
python ingest_data.py
```
Crea una tabla por archivo con el mismo nombre. **Todo se carga como texto** para que Python no
altere los datos (por ejemplo, convertir `1.00114E+12` a float o `None` a NaN); la limpieza es SQL.

### 4. Transformaciones en SQL
Ejecuta en orden `00_funciones.sql`, `01_vistas.sql` y `05_materializar.sql`.
Para ejecutar los scripts opcionales y ver sus resultados con `psql`:
```bash
docker cp 03_verificacion.sql postgres_analitica:/tmp/03_verificacion.sql
docker exec -it postgres_analitica psql -U postgres -d analitica_inversiones -f /tmp/03_verificacion.sql
```
(igual con `02_diagnostico.sql` y `04_investigacion.sql`). En `03`, el bloque A debe dar `diferencia_cuadre = 0`.

### 5. Aplicación Django
```bash
python manage.py migrate
python manage.py runserver 8080
```
Abrir http://127.0.0.1:8080. Se elige el cliente y se ve su portafolio COP (dona por macroactivo y tabla de
activos) y USD (principales posiciones), siempre a su **última fecha disponible**.
La configuración de base de datos está en `config/settings.py` (`HOST=127.0.0.1`, `PORT=5433`, `CONN_MAX_AGE=600`).

### 6. Modelo analítico
```bash
python modelo_analitico.py                # con TRM y volatilidad de mercado (yfinance, requiere internet)
python modelo_analitico.py --sin-mercado  # sin internet (TRM por defecto 3.900, sin volatilidad)
python modelo_analitico.py --trm 3850     # TRM manual
```
Guarda `resultados/clientes_segmentados.csv` y la tabla `resultado_clientes` en PostgreSQL (se reemplaza en
cada ejecución).

**Variables de entorno opcionales** (si no se definen, se usan los valores por defecto del README):
`DB_USER`, `DB_PASS`, `DB_HOST`, `DB_PORT`, `DB_NAME` y `TRM_COP_USD` (TRM por defecto).

## Calidad de datos: problemas encontrados y cómo se resolvieron (todo en SQL)

| Problema | Impacto | Tratamiento |
|---|---|---|
| Filas duplicadas exactas | 783 en COP (6.694 → 5.911), 543 en USD (5.750 → 5.207) | `DISTINCT` sobre los registros limpios |
| IDs en notación científica (`1.00114E+12`) | 1.573 filas, 11 clientes, ~60 % del saldo; Excel truncó los dígitos y no son recuperables | Se conservan como `SCI-<token>` con bandera `id_aproximado` (no se cruzan con USD) |
| ID con un dígito menos (`1002203023`) | 1 fila | Corregido a `10020203023` (tabla `correccion_id_cliente`, distancia de edición = 1) |
| Coma dentro del ID (`100` + `32184607`) y columnas corridas | 11 filas, ~0,14 % del saldo | Excluidas y documentadas |
| `None`, vacíos y espacios | `cod_activo`, `macroactivo`, `cod_banca`, `ingestion_month`… | `limpiar_texto()`; macroactivo, banca y perfil se completan por moda del activo/cliente; mes faltante desde las columnas `year`/`month` |
| Códigos de activo inválidos | `10007` (cero de más), `1115` en catálogo vs `1015` en datos, `1022` inexistente | Tabla `correccion_cod_activo` (supuestos editables); `1022` queda como "ACTIVO NO CATALOGADO" |
| `PR` duplicado en `catalogo_banca` | El `LEFT JOIN` duplicaba filas y saldos | Catálogos deduplicados (`DISTINCT ON`) |
| Números con formato mixto | Comas decimales, separadores de miles | `numero_seguro()` devuelve `NULL` (no 0) si no puede interpretar el valor |
| `1/01/1900` en `fecha_vencimiento` | Fecha nula de Excel | Convertida a `NULL` |

## Modelo analítico

### 1. Features por cliente
Una fila por cliente, con:

- **Patrimonio total** (COP + USD convertido a TRM) y **% en USD**.
- **Concentración:** índice HHI y peso de la mayor posición (COP y USD).
- **Composición** por macroactivo (renta fija, renta variable, FICs), % en liquidez y % sin código de activo.
- **Perfil de riesgo y banca** del cliente.
- **Volatilidad anualizada ponderada** del portafolio USD (opcional, vía `yfinance`).

**Datos de mercado (opcionales).** Si hay internet, el modelo consulta en Yahoo Finance:

- La **TRM** (`COP=X`) cercana a la fecha de corte. Es una cotización de mercado, **no** la TRM oficial
  certificada; para usar la oficial se pasa con `--trm`.
- La **volatilidad a 1 año** de cada acción/ETF.

Antes de consultar, los símbolos se **normalizan**: se aplican alias de tickers que cambiaron
(por ejemplo, `SQ` → `XYZ`) y se descartan los códigos que no son tickers de bolsa (vacíos o con dígitos,
como códigos internos de títulos). Los avisos de `yfinance` se silencian. Los activos sin volatilidad
disponible simplemente no entran en el promedio ponderado. Si no hay internet, el modelo sigue funcionando
con la TRM por defecto y sin volatilidad.

### 2. Segmentación
K-Means sobre variables estandarizadas: log del patrimonio, % USD, HHI, % renta variable y % renta fija.

- `k` entre 2 y 4, elegido por **silhouette**.
- Un grupo con **menos de 3 clientes** no se considera segmento: se marca como
  **"Atípico (revisión individual)"** (columna `es_atipico`) para que un caso raro no invalide toda la
  segmentación.
- Se aceptan como máximo un **10 % de clientes atípicos** y al menos 2 segmentos reales; en caso contrario
  ese `k` se descarta. Si ningún `k` cumple, todos los clientes quedan en un único segmento.
- El silhouette se calcula **sin los atípicos**, para que un grupo de una sola persona no infle el puntaje.
- Cada segmento se nombra automáticamente según su patrimonio (alto / medio / bajo, por cuartiles) y su
  estilo (exposición internacional, sesgo renta variable, sesgo renta fija o balanceado / FICs).
- Los parámetros se ajustan en las constantes `K_MAX`, `MIN_POR_SEGMENTO` y `MAX_PCT_ATIPICOS` de
  `modelo_analitico.py`. Durante la ejecución se imprime, para cada `k`, el tamaño de los grupos y su
  silhouette, de modo que la elección sea auditable.

### 3. Next Best Action
Reglas explicables, evaluadas por cliente (no dependen del segmento). Un cliente puede recibir varias alertas:

| Regla | Condición |
|---|---|
| Idoneidad: perfil sin definir | `perfil_riesgo = SIN DEFINIR` → aplicar test antes de ofertar productos |
| Idoneidad: perfil conservador | `CONSERVADOR` con más de 40 % en renta variable |
| Oportunidad: perfil agresivo | `AGRESIVO` con más de 80 % en renta fija |
| Concentración | Más de 60 % en un solo activo COP (con más de un activo) |
| Cobertura cambiaria | Sin exposición USD y patrimonio igual o mayor a la mediana |
| Liquidez ociosa | Más de 30 % en liquidez COP (`Renta Liquidez`, `Fiducuenta`) |
| Riesgo de emisor en USD | Más de 40 % en una sola posición USD |
| Volatilidad USD alta | Volatilidad ponderada mayor a 30 % en perfil `CONSERVADOR` |
| Calidad de datos | Más de 10 % del portafolio sin código de activo |

Si ninguna regla se activa, la recomendación es "Portafolio balanceado: mantener estrategia y rebalancear
semestralmente".

### Salida
`resultados/clientes_segmentados.csv` y la tabla `resultado_clientes` incluyen, además de las features,
las columnas `cluster_id`, `segmento`, `es_atipico`, `k`, `silhouette_k`, `n_alertas` y
`siguiente_mejor_accion`.

### Resultado de referencia (corte 2024-05-15, 29 clientes)

| Segmento | Clientes | Patrimonio mediano (COP) | % USD medio |
|---|---|---|---|
| C0: Patrimonio alto, con exposición internacional | 11 | 2.282 M | 95 % |
| C1: Patrimonio medio, balanceado / FICs | 9 | 127 M | 0 % |
| C2: Patrimonio bajo, sesgo renta variable | 8 | 1,7 M | 0 % |
| C3: Atípico (revisión individual) | 1 | 2.110 M | 13 % |

Con `k = 4` y silhouette ≈ 0,46 (sin atípicos). Son cifras de ejemplo: cambian si cambian los datos o la TRM.

## Limitaciones

- **Muestra pequeña:** 29 clientes con ID válido o aproximado. El silhouette (~0,46) indica una estructura
  moderada, no segmentos fuertemente separados.
- **Reglas heurísticas:** son criterios de negocio explicables, no un modelo predictivo.
- **Clientes `SCI-`:** su ID es aproximado y **no cruza con USD**. Por eso la regla de cobertura cambiaria
  puede dispararse para ellos aunque tengan posiciones USD que el modelo no ve; esa alerta debe tomarse como
  no verificable.
- **TRM:** la que se obtiene de Yahoo Finance es de mercado, no la oficial; la TRM por defecto (3.900) es
  aproximada.
- **Volatilidad:** solo cubre símbolos que Yahoo reconoce como tickers de bolsa; los títulos con códigos
  internos no entran. Si algún código de ese tipo aparece como `Acción / ETF` en `mv_portafolio_usd_ultimo`,
  conviene revisar su clasificación en el SQL.
- **Atípicos:** un cliente marcado como atípico no es necesariamente "malo"; solo no se parece a ningún grupo
  y requiere revisión individual (y verificar que sus datos, incluidas las correcciones de ID, sean correctos).

## Notas técnicas

- **PostgreSQL 17+:** las vistas materializadas se crean con `search_path` restringido; por eso `05_materializar.sql`
  fija el `search_path` de las funciones.
- Si se recargan los datos o se modifica `01_vistas.sql`, volver a ejecutar `python run_sql.py` y luego
  `python modelo_analitico.py`.
- En Windows se usa `127.0.0.1` en lugar de `localhost` para evitar la demora por resolución IPv6.