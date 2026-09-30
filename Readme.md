# Analítica de Inversiones - Paso 1: Carga de Datos


## Requisitos previos

- Docker Desktop / Docker Engine
- Python 3.10 o superior

## Estructura del proyecto

```text
Inversiones_Cibest/
│
├── data/                                 # Archivos .csv de entrada
│   ├── cat_perfil_riesgo.csv
│   ├── catalogo_activos.csv
│   ├── catalogo_banca.csv
│   ├── historico_aba_macroactivos.csv
│   └── historico_aba_usd_internacional.csv
│
├── .gitignore                            # Exclusión de data y venv
├── docker-compose.yml                    # Configuración de PostgreSQL
├── ingest_data.py                        # Script de ingesta 
├── requirements.txt                      # Librerías requeridas
├── venv/                                
└── README.md
```

## Paso a paso para la ejecución

### 1. Levantamiento de la base de datos
Asegúrate de tener Docker corriendo y ejecuta en la terminal:
```
docker compose up -d
```

### 2. Entorno virtual e instalación de dependencias
Crea y activa el entorno virtual de Python:

```
# Crear entorno virtual
python -m venv venv

# Activar en Windows (PowerShell)
.\venv\Scripts\Activate

pip install -r requirements.txt
```

### 3. Ingesta de datos
Ejecuta el script
```
python ingest_data.py
```
