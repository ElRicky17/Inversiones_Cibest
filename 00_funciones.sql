-- =====================================================================
-- 00_funciones.sql
-- Funciones de limpieza. Asumen que las tablas crudas se cargaron
-- con TODAS las columnas como TEXT (dtype=str en pandas).
-- =====================================================================

-- Limpia espacios (incluye NBSP) y convierte 'None', 'NaN', '' etc. en NULL
CREATE OR REPLACE FUNCTION limpiar_texto(p TEXT) RETURNS TEXT AS $$
    SELECT NULLIF(
        CASE WHEN UPPER(v) IN ('NONE','NULL','NAN','N/A','NA','#N/A','-','--')
             THEN '' ELSE v END, '')
    FROM (SELECT REGEXP_REPLACE(p, '^[\s\u00a0]+|[\s\u00a0]+$', '', 'g') AS v) s;
$$ LANGUAGE sql IMMUTABLE;

-- Entero seguro: '2024', '2024.0', ' 12 ' -> INT; basura -> NULL
CREATE OR REPLACE FUNCTION entero_texto(p TEXT) RETURNS INT AS $$
DECLARE
    v TEXT := limpiar_texto(p);
BEGIN
    IF v IS NULL THEN RETURN NULL; END IF;
    v := REGEXP_REPLACE(SPLIT_PART(v, '.', 1), '[^0-9]', '', 'g');
    RETURN NULLIF(v, '')::INT;
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Código numérico como texto: '1468.0' -> '1468', ' 1004 ' -> '1004'
CREATE OR REPLACE FUNCTION codigo_texto(p TEXT) RETURNS TEXT AS $$
    SELECT NULLIF(
        REGEXP_REPLACE(
            REGEXP_REPLACE(COALESCE(limpiar_texto(p), ''), '\.0+$', ''),
            '[^0-9]', '', 'g'),
        '');
$$ LANGUAGE sql IMMUTABLE;

-- Fecha segura: NULL si falta algún componente o la fecha no existe
CREATE OR REPLACE FUNCTION fecha_segura(p_year TEXT, p_month TEXT, p_day TEXT)
RETURNS DATE AS $$
DECLARE
    y INT := entero_texto(p_year);
    m INT := entero_texto(p_month);
    d INT := entero_texto(p_day);
BEGIN
    IF y IS NULL OR m IS NULL OR d IS NULL THEN RETURN NULL; END IF;
    RETURN MAKE_DATE(y, m, d);
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Numérico seguro: maneja '1234.56', '1234,56', '1.234,56', '1,234.56', '1.05E+09'
-- Devuelve NULL (no 0) si no se puede interpretar, para no esconder errores.
CREATE OR REPLACE FUNCTION numero_seguro(p TEXT) RETURNS NUMERIC AS $$
DECLARE
    v         TEXT := limpiar_texto(p);
    ult_coma  INT;
    ult_punto INT;
    n_comas   INT;
    n_puntos  INT;
BEGIN
    IF v IS NULL THEN RETURN NULL; END IF;
    v := REGEXP_REPLACE(v, '[^0-9eE+.,-]', '', 'g');
    IF v = '' THEN RETURN NULL; END IF;

    n_comas  := LENGTH(v) - LENGTH(REPLACE(v, ',', ''));
    n_puntos := LENGTH(v) - LENGTH(REPLACE(v, '.', ''));
    ult_coma  := CASE WHEN n_comas  = 0 THEN 0 ELSE LENGTH(v) - STRPOS(REVERSE(v), ',') + 1 END;
    ult_punto := CASE WHEN n_puntos = 0 THEN 0 ELSE LENGTH(v) - STRPOS(REVERSE(v), '.') + 1 END;

    IF ult_coma > 0 AND ult_punto > 0 THEN
        -- el separador que aparece de último es el decimal
        IF ult_coma > ult_punto THEN
            v := REPLACE(REPLACE(v, '.', ''), ',', '.');
        ELSE
            v := REPLACE(v, ',', '');
        END IF;
    ELSIF ult_coma > 0 THEN
        IF n_comas > 1 THEN v := REPLACE(v, ',', '');   -- 1,234,567
        ELSE v := REPLACE(v, ',', '.');                 -- 1234,56
        END IF;
    ELSIF n_puntos > 1 THEN
        v := REPLACE(v, '.', '');                       -- 1.234.567
    END IF;

    RETURN v::NUMERIC;
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- ¿El ID vino en notación científica? (dato irrecuperable: Excel truncó los dígitos)
CREATE OR REPLACE FUNCTION id_es_notacion_cientifica(p TEXT) RETURNS BOOLEAN AS $$
    SELECT COALESCE(limpiar_texto(p) ~* '^[0-9]+(\.[0-9]+)?e[+-]?[0-9]+$', FALSE);
$$ LANGUAGE sql IMMUTABLE;

-- ID de cliente como texto de solo dígitos
CREATE OR REPLACE FUNCTION id_cliente_texto(p TEXT) RETURNS TEXT AS $$
DECLARE
    v TEXT := limpiar_texto(p);
BEGIN
    IF v IS NULL THEN RETURN NULL; END IF;
    IF id_es_notacion_cientifica(v) THEN
        RETURN (v::NUMERIC)::BIGINT::TEXT;
    END IF;
    RETURN codigo_texto(v);
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Fecha de vencimiento: soporta DD/MM/YYYY y ISO; 1900 (placeholder Excel) -> NULL
CREATE OR REPLACE FUNCTION fecha_vencimiento_segura(p TEXT) RETURNS DATE AS $$
DECLARE
    v TEXT := limpiar_texto(p);
    r DATE;
BEGIN
    IF v IS NULL THEN RETURN NULL; END IF;
    IF v ~ '^\d{4}-\d{1,2}-\d{1,2}' THEN
        r := TO_DATE(SUBSTRING(v FROM 1 FOR 10), 'YYYY-MM-DD');
    ELSE
        r := TO_DATE(v, 'DD/MM/YYYY');
    END IF;
    IF r < DATE '1950-01-01' THEN RETURN NULL; END IF;
    RETURN r;
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END;
$$ LANGUAGE plpgsql IMMUTABLE;