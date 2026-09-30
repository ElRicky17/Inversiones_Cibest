# Analítica de Inversiones - Carga y Transformación de Datos

Este módulo inicial contiene la configuración de la base de datos PostgreSQL en Docker, el script en Python para poblar las tablas base (Capa Raw) y el archivo de scripts SQL encargado de realizar las transformaciones para estructurar la Capa Gold y de Auditoría.

## Requisitos previos

- Docker Desktop / Docker Engine
- Python 3.10 o superior

## Estructura del proyecto

```text
Inversiones_Cibest/
│
├── data/                                 # Archivos .csv de entrada (Raw Data)
│   ├── cat_perfil_riesgo.csv
│   ├── catalogo_activos.csv
│   ├── catalogo_banca.csv
│   ├── historico_aba_macroactivos.csv
│   └── historico_aba_usd_internacional.csv
│
├── .gitignore                            # Exclusión de data/ y venv/
├── docker-compose.yml                    # Contenedor de PostgreSQL
├── ingest_data.py                        # Script de ingesta inicial
├── transformations.sql                   # Funciones de limpieza, Vistas Gold y Auditoría
├── requirements.txt                      # Librerías de Python
└── README.md
```

---

## Archivos de Configuración Básicos

### 1. `docker-compose.yml`
```yaml
services:
  db:
    image: postgres:latest
    container_name: postgres_analitica
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: 12345
      POSTGRES_DB: analitica_inversiones
    ports:
      - "5433:5432"
    restart: unless-stopped
```

### 2. `.gitignore`
```text
# Entorno virtual
venv/

# Datos locales compartidos
data/*.csv
```

### 3. `requirements.txt`
```text
pandas
sqlalchemy
psycopg2-binary
```

---

## Paso a paso para la ejecución

### 1. Levantamiento de la base de datos
Asegúrate de tener Docker ejecutándose y corre el comando:
```bash
docker compose up -d
```

### 2. Entorno virtual e instalación de dependencias
Crea, activa el entorno virtual e instala las librerías necesarias:

```bash
# Crear entorno virtual
python -m venv venv

# Activar en Windows (PowerShell)
.\venv\Scripts\Activate.ps1

# Activar en Linux / macOS
source venv/bin/activate
```

Instalar librerías:
```bash
pip install -r requirements.txt
```

### 3. Ingesta de datos (Capa Raw)
Carga la información de los archivos CSV hacia PostgreSQL ejecutando:
```bash
python ingest_data.py
```

### 4. Transformación y Limpieza de Datos (Capa Gold y Auditoría)
Ejecuta las reglas de limpieza y creación de vistas analíticas directo en PostgreSQL inyectando el script SQL al contenedor de Docker:
```bash
docker exec -i postgres_analitica psql -U postgres -d analitica_inversiones < transformations.sql
```

---

## ¿Qué hace `transformations.sql` y por qué es necesario?

Los datos crudos de las fuentes presentan inconsistencias de formato. El archivo `transformations.sql` soluciona esto sin alterar los datos originales mediante:

* **Casteos y Funciones Seguras (`safe_cast_numeric`, `safe_make_date`):**
  * **Por qué:** Evitan que la base de datos falle al intentar procesar fechas corruptas (ej. `2024--27`) o saldos con formatos numéricos no estándar (comas decimales, espacios o texto).

* **Vistas Analíticas (`vista_portafolio_cop` y `vista_portafolio_usd`):**
  * **Por qué:** Limpian cédulas, estandarizan nombres de activos y categorías, cruzan la información con los catálogos y entregan un portafolio unificado con valores estandarizados para analítica.

* **Vista de Auditoría (`vista_auditoria_registros_corruptos`):**
  * **Por qué:** Captura y aísla los registros con errores irrecuperables (fechas o saldos inválidos), indicando la causa exacta de rechazo para fácil trazabilidad sin afectar los reportes operativos.
