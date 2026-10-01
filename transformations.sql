-- 1. Función para limpiar y castear valores numéricos
CREATE OR REPLACE FUNCTION safe_cast_numeric(p_value TEXT)
RETURNS NUMERIC AS $$
BEGIN
    IF p_value IS NULL OR TRIM(p_value) = '' THEN
        RETURN 0.0;
    END IF;
    RETURN CAST(REPLACE(TRIM(p_value), ',', '.') AS NUMERIC);
EXCEPTION WHEN OTHERS THEN
    RETURN 0.0;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- 2. Función para parsear fechas de forma segura
CREATE OR REPLACE FUNCTION safe_make_date(p_year TEXT, p_month TEXT, p_day TEXT)
RETURNS DATE AS $$
DECLARE
    v_year INT;
    v_month INT;
    v_day INT;
BEGIN
    v_year  := CAST(REGEXP_REPLACE(p_year, '[^0-9]', '', 'g') AS INT);
    v_month := CAST(REGEXP_REPLACE(p_month, '[^0-9]', '', 'g') AS INT);
    v_day   := CAST(REGEXP_REPLACE(p_day, '[^0-9]', '', 'g') AS INT);

    IF v_year IS NULL OR v_month IS NULL OR v_day IS NULL THEN
        RETURN NULL;
    END IF;

    RETURN MAKE_DATE(v_year, v_month, v_day);
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- 3. Función para limpiar IDs de clientes (Resuelve notación científica 1.00114E+12)
CREATE OR REPLACE FUNCTION clean_client_id(p_value TEXT)
RETURNS TEXT AS $$
DECLARE
    v_clean TEXT;
BEGIN
    IF p_value IS NULL OR TRIM(p_value) = '' THEN
        RETURN NULL;
    END IF;

    v_clean := TRIM(p_value);

    -- Si viene en notación científica E+12 o similar, expandirlo a entero
    IF v_clean ~* '[0-9]+(\.[0-9]+)?E\+[0-9]+' THEN
        RETURN CAST(CAST(v_clean AS NUMERIC) AS BIGINT)::text;
    END IF;

    -- Si es número estándar, quitar caracteres no numéricos
    RETURN NULLIF(REGEXP_REPLACE(v_clean, '[^0-9]', '', 'g'), '');
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- 4. VISTA PORTAFOLIO LOCAL (COP)
CREATE OR REPLACE VIEW vista_portafolio_cop AS
WITH datos_normalizados AS (
    SELECT 
        f.ingestion_year::text AS ingestion_year,
        f.ingestion_month::text AS ingestion_month,
        
        CASE 
            WHEN LENGTH(TRIM(f.ingestion_day::text)) > 2 THEN SUBSTRING(TRIM(f.ingestion_day::text) FROM 1 FOR 2)
            ELSE TRIM(f.ingestion_day::text)
        END AS ingestion_day_limpio,
        
        clean_client_id(f.id_sistema_cliente::text) AS id_sistema_cliente_limpio,
        NULLIF(REGEXP_REPLACE(TRIM(f.cod_activo::text), '[^0-9]', '', 'g'), '') AS cod_activo_limpio,
        
        COALESCE(
            NULLIF(TRIM(REGEXP_REPLACE(f.macroactivo::text, '^[0-9]+', '')), ''),
            NULLIF(TRIM(f.macroactivo::text), ''),
            'SIN CLASIFICAR'
        ) AS macroactivo_limpio,
        
        f.aba::text AS saldo_cop_raw,
        f.cod_perfil_riesgo::text AS cod_perfil_riesgo,
        f.cod_banca::text AS cod_banca
    FROM historico_aba_macroactivos f
)
SELECT 
    safe_make_date(dn.ingestion_year, dn.ingestion_month, dn.ingestion_day_limpio) AS fecha_corte,
    dn.id_sistema_cliente_limpio AS id_sistema_cliente,
    dn.cod_activo_limpio AS cod_activo,
    COALESCE(NULLIF(TRIM(a.activo::text), ''), 'SIN NOMBRE ASIGNADO') AS nombre_activo,
    dn.macroactivo_limpio AS macroactivo,
    safe_cast_numeric(dn.saldo_cop_raw) AS saldo_cop,
    COALESCE(NULLIF(TRIM(p.perfil_riesgo::text), ''), 'NO REGISTRA') AS perfil_riesgo,
    COALESCE(NULLIF(TRIM(b.banca::text), ''), 'NO REGISTRA') AS banca

FROM datos_normalizados dn
LEFT JOIN catalogo_activos a ON dn.cod_activo_limpio = TRIM(a.cod_activo::text)
LEFT JOIN cat_perfil_riesgo p ON dn.cod_perfil_riesgo = TRIM(p.cod_perfil_riesgo::text)
LEFT JOIN catalogo_banca b ON dn.cod_banca = TRIM(b.cod_banca::text)

WHERE dn.id_sistema_cliente_limpio IS NOT NULL;

-- 5. VISTA PORTAFOLIO INTERNACIONAL (USD)
CREATE OR REPLACE VIEW vista_portafolio_usd AS
WITH datos_usd AS (
    SELECT 
        f.year::text AS year,
        f.month::text AS month,
        f.day::text AS day,
        clean_client_id(f.id_sistema_cliente::text) AS id_sistema_cliente_limpio,
        NULLIF(REGEXP_REPLACE(TRIM(f.cod_activo::text), '[^0-9]', '', 'g'), '') AS cod_activo_limpio,
        f.saldo_usd::text AS saldo_usd_raw
    FROM historico_posicion_usd f
)
SELECT 
    safe_make_date(u.year, u.month, u.day) AS fecha_corte,
    u.id_sistema_cliente_limpio AS id_sistema_cliente,
    u.cod_activo_limpio AS cod_activo,
    COALESCE(NULLIF(TRIM(a.activo::text), ''), 'SIN NOMBRE ASIGNADO') AS nombre_activo,
    safe_cast_numeric(u.saldo_usd_raw) AS saldo_usd

FROM datos_usd u
LEFT JOIN catalogo_activos a ON u.cod_activo_limpio = TRIM(a.cod_activo::text)

WHERE u.id_sistema_cliente_limpio IS NOT NULL;