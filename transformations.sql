-- ============================================================================
-- SCRIPT DE DESPLIEGUE FINAL: MODELO DE DATOS Y TRATAMIENTO DE ERRORES
-- BASE DE DATOS: analitica_inversiones
-- ENGINE: PostgreSQL 12+
-- ============================================================================

-- ============================================================================
-- PASO 1: LIMPIEZA DE OBJETOS PREVIOS
-- ============================================================================

DROP VIEW IF EXISTS vista_auditoria_registros_corruptos CASCADE;
DROP VIEW IF EXISTS vista_portafolio_usd CASCADE;
DROP VIEW IF EXISTS vista_portafolio_cop CASCADE;

DROP FUNCTION IF EXISTS safe_make_date(ANYELEMENT, ANYELEMENT, ANYELEMENT);
DROP FUNCTION IF EXISTS safe_make_date(TEXT, TEXT, TEXT);
DROP FUNCTION IF EXISTS safe_cast_numeric(ANYELEMENT);
DROP FUNCTION IF EXISTS safe_cast_numeric(TEXT);

-- ============================================================================
-- PASO 2: FUNCIONES DE CASTEO SEGURO (SAFE CASTS)
-- Previene excepciones críticas ante formatos corruptos
-- ============================================================================

-- 2.1 Casteo seguro a NUMERIC (Maneja comas decimales y cadenas inválidas)
CREATE OR REPLACE FUNCTION safe_cast_numeric(p_value TEXT) 
RETURNS NUMERIC AS $$
BEGIN
    IF p_value IS NULL OR TRIM(p_value) = '' THEN 
        RETURN NULL; 
    END IF;
    RETURN CAST(REPLACE(TRIM(p_value), ',', '.') AS NUMERIC);
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- 2.2 Reconstrucción segura de FECHA con soporte a decimales en meses/días
CREATE OR REPLACE FUNCTION safe_make_date(p_year TEXT, p_month TEXT, p_day TEXT) 
RETURNS DATE AS $$
DECLARE
    v_y INT;
    v_m INT;
    v_d INT;
BEGIN
    IF p_year IS NULL OR p_month IS NULL OR p_day IS NULL THEN
        RETURN NULL;
    END IF;

    -- Extrae la parte entera por si vienen flotantes (ej. '4.0')
    v_y := CAST(SPLIT_PART(TRIM(p_year), '.', 1) AS INT);
    v_m := CAST(SPLIT_PART(TRIM(p_month), '.', 1) AS INT);
    v_d := CAST(SPLIT_PART(TRIM(p_day), '.', 1) AS INT);
    
    RETURN MAKE_DATE(v_y, v_m, v_d);
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- ============================================================================
-- PASO 3: VISTAS DEL NEGOCIO (CAPA GOLD)
-- ============================================================================

-------------------------------------------------------------------------------
-- 3.1 Vista Portafolio Local (COP)
-------------------------------------------------------------------------------
CREATE VIEW vista_portafolio_cop AS
WITH datos_normalizados AS (
    SELECT 
        f.ingestion_year::text AS ingestion_year,
        f.ingestion_month::text AS ingestion_month,
        
        -- Si el día viene pegado con la cédula, extrae los 2 primeros caracteres
        CASE 
            WHEN LENGTH(TRIM(f.ingestion_day::text)) > 2 THEN SUBSTRING(TRIM(f.ingestion_day::text) FROM 1 FOR 2)
            ELSE TRIM(f.ingestion_day::text)
        END AS ingestion_day_limpio,
        
        NULLIF(REGEXP_REPLACE(TRIM(f.id_sistema_cliente::text), '[^0-9]', '', 'g'), '') AS id_sistema_cliente_limpio,
        NULLIF(REGEXP_REPLACE(TRIM(f.cod_activo::text), '[^0-9]', '', 'g'), '') AS cod_activo_limpio,
        
        -- Limpia prefijos pegados como '100FICs' -> 'FICs'
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


-------------------------------------------------------------------------------
-- 3.2 Vista Portafolio USD Internacional
-------------------------------------------------------------------------------
CREATE VIEW vista_portafolio_usd AS
SELECT 
    safe_make_date(ingestion_year::text, ingestion_month::text, ingestion_day::text) AS fecha_corte,
    
    NULLIF(REGEXP_REPLACE(TRIM(id_sistema_cliente::text), '[^0-9]', '', 'g'), '') AS id_sistema_cliente,
    NULLIF(TRIM(simbol::text), '') AS simbol,
    NULLIF(TRIM(cusip::text), '') AS cusip,
    NULLIF(TRIM(isin::text), '') AS isin,
    
    COALESCE(NULLIF(TRIM(nombre_activo::text), ''), NULLIF(TRIM(simbol::text), ''), 'ACTIVO INTERNACIONAL') AS nombre_activo,
    
    safe_cast_numeric(cantidad::text) AS cantidad,
    safe_cast_numeric(valor_mercado::text) AS saldo_usd,
    
    CASE 
        WHEN fecha_vencimiento::text IN ('1900-01-01', '1/01/1900', '01/01/1900') OR fecha_vencimiento IS NULL THEN NULL
        ELSE TO_DATE(NULLIF(TRIM(fecha_vencimiento::text), ''), 'MM/DD/YYYY')
    END AS fecha_vencimiento,
    
    CASE 
        WHEN safe_cast_numeric(tasa_cupon::text) = 0 THEN NULL
        ELSE safe_cast_numeric(tasa_cupon::text)
    END AS tasa_cupon

FROM historico_aba_usd_internacional
WHERE NULLIF(TRIM(id_sistema_cliente::text), '') IS NOT NULL;


-- ============================================================================
-- PASO 4: VISTA DE AUDITORÍA Y CONTROL DE CALIDAD
-- ============================================================================

CREATE VIEW vista_auditoria_registros_corruptos AS
SELECT 
    'historico_aba_macroactivos' AS tabla_origen,
    f.id_sistema_cliente::text AS id_sistema_cliente,
    COALESCE(f.ingestion_year::text, '') || '-' || COALESCE(f.ingestion_month::text, '') || '-' || COALESCE(f.ingestion_day::text, '') AS fecha_original,
    f.aba::text AS saldo_original,
    CASE 
        WHEN safe_make_date(f.ingestion_year::text, f.ingestion_month::text, f.ingestion_day::text) IS NULL THEN 'Fecha Invalida / Formato Incorrecto'
        WHEN safe_cast_numeric(f.aba::text) IS NULL THEN 'Saldo Invalido / No Numerico'
        ELSE 'Otro error de formato'
    END AS motivo_rechazo
FROM historico_aba_macroactivos f
WHERE safe_make_date(f.ingestion_year::text, f.ingestion_month::text, f.ingestion_day::text) IS NULL
   OR safe_cast_numeric(f.aba::text) IS NULL;