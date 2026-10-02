-- =====================================================================
-- 01_vistas.sql
-- Catálogos limpios, vistas base y vistas finales de portafolio.
-- Requiere haber ejecutado 00_funciones.sql
-- =====================================================================

DROP VIEW IF EXISTS vista_portafolio_cop_ultimo CASCADE;
DROP VIEW IF EXISTS vista_portafolio_usd_ultimo CASCADE;
DROP VIEW IF EXISTS vista_portafolio_cop CASCADE;
DROP VIEW IF EXISTS vista_portafolio_usd CASCADE;
DROP VIEW IF EXISTS v_macro_limpio CASCADE;
DROP VIEW IF EXISTS v_macro_base CASCADE;
DROP VIEW IF EXISTS v_mapa_activo_macro CASCADE;
DROP VIEW IF EXISTS v_mapa_cliente CASCADE;
DROP VIEW IF EXISTS v_usd_limpio CASCADE;
DROP VIEW IF EXISTS v_catalogo_activos CASCADE;
DROP VIEW IF EXISTS v_catalogo_banca CASCADE;
DROP VIEW IF EXISTS v_cat_perfil_riesgo CASCADE;

-- ---------------------------------------------------------------------
-- Correcciones manuales de códigos de activo (SUPUESTOS: validar)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS correccion_cod_activo (
    cod_origen  TEXT PRIMARY KEY,
    cod_destino TEXT NOT NULL,
    motivo      TEXT
);
INSERT INTO correccion_cod_activo (cod_origen, cod_destino, motivo) VALUES
    ('10007', '1007', 'Código con un cero de más; FICs -> Fiducuenta (supuesto)'),
    ('1115',  '1015', 'Catálogo trae PFCEMARGOS como 1115, el histórico usa 1015 (supuesto)')
ON CONFLICT (cod_origen) DO NOTHING;

-- Correcciones de IDs de cliente (typos detectados con levenshtein = 1)
CREATE TABLE IF NOT EXISTS correccion_id_cliente (
    id_origen  TEXT PRIMARY KEY,
    id_destino TEXT NOT NULL,
    motivo     TEXT
);
INSERT INTO correccion_id_cliente (id_origen, id_destino, motivo) VALUES
    ('1002203023', '10020203023', 'Typo: un dígito menos; candidato con 852 filas (supuesto)')
ON CONFLICT (id_origen) DO NOTHING;

-- ID final de cliente:
--  * notación científica  -> 'SCI-<token expandido>' (ID aproximado, no recuperable)
--  * largo < 9 dígitos     -> NULL (fragmento inválido, ej. '100')
--  * typos conocidos       -> corregidos desde correccion_id_cliente
CREATE OR REPLACE FUNCTION id_cliente_final(p TEXT) RETURNS TEXT AS $$
DECLARE
    v TEXT := id_cliente_texto(p);
    d TEXT;
BEGIN
    IF v IS NULL THEN RETURN NULL; END IF;
    IF id_es_notacion_cientifica(p) THEN RETURN 'SCI-' || v; END IF;
    IF LENGTH(v) < 9 THEN RETURN NULL; END IF;
    SELECT id_destino INTO d FROM correccion_id_cliente WHERE id_origen = v;
    RETURN COALESCE(d, v);
END;
$$ LANGUAGE plpgsql STABLE;

-- ---------------------------------------------------------------------
-- Catálogos limpios y SIN duplicados (evita multiplicar filas en los JOIN)
-- ---------------------------------------------------------------------
CREATE VIEW v_catalogo_activos AS
SELECT DISTINCT ON (cod) cod AS cod_activo, nombre AS nombre_activo
FROM (
    SELECT COALESCE(c.cod_destino, codigo_texto(a.cod_activo)) AS cod,
           REGEXP_REPLACE(limpiar_texto(a.activo), '\s+', ' ', 'g')  AS nombre
    FROM catalogo_activos a
    LEFT JOIN correccion_cod_activo c ON c.cod_origen = codigo_texto(a.cod_activo)
) x
WHERE cod IS NOT NULL
ORDER BY cod, (nombre IS NULL), nombre;

CREATE VIEW v_catalogo_banca AS
SELECT DISTINCT ON (cod) cod AS cod_banca, nombre AS banca
FROM (
    SELECT UPPER(limpiar_texto(cod_banca)) AS cod,
           limpiar_texto(banca)            AS nombre
    FROM catalogo_banca
) x
WHERE cod IS NOT NULL
ORDER BY cod, (nombre IS NULL), nombre;

CREATE VIEW v_cat_perfil_riesgo AS
SELECT DISTINCT ON (cod) cod AS cod_perfil_riesgo, nombre AS perfil_riesgo
FROM (
    SELECT codigo_texto(cod_perfil_riesgo) AS cod,
           limpiar_texto(perfil_riesgo)    AS nombre
    FROM cat_perfil_riesgo
) x
WHERE cod IS NOT NULL
ORDER BY cod, (nombre IS NULL), nombre;

-- ---------------------------------------------------------------------
-- COP: base limpia (una fila por registro crudo, sin duplicados exactos)
-- NOTA: se asume que las dos últimas columnas del CSV se llaman year y month
-- ---------------------------------------------------------------------
CREATE VIEW v_macro_base AS
SELECT DISTINCT
    fecha_segura(
        COALESCE(limpiar_texto(f.ingestion_year),  limpiar_texto(f."year")),
        COALESCE(limpiar_texto(f.ingestion_month), limpiar_texto(f."month")),
        f.ingestion_day
    )                                                   AS fecha_corte,
    id_cliente_final(f.id_sistema_cliente)              AS id_sistema_cliente,
    id_es_notacion_cientifica(f.id_sistema_cliente)     AS id_corrupto,
    COALESCE(cc.cod_destino, codigo_texto(f.cod_activo)) AS cod_activo,
    NULLIF(UPPER(BTRIM(REGEXP_REPLACE(
        COALESCE(limpiar_texto(f.macroactivo), ''), '^[0-9]+', ''))), '') AS macroactivo_raw,
    numero_seguro(f.aba)                                AS saldo_cop,
    codigo_texto(f.cod_perfil_riesgo)                   AS cod_perfil_riesgo,
    UPPER(limpiar_texto(f.cod_banca))                   AS cod_banca
FROM historico_aba_macroactivos f
LEFT JOIN correccion_cod_activo cc ON cc.cod_origen = codigo_texto(f.cod_activo);

-- Macroactivo más frecuente por activo (para rellenar vacíos / 'None')
CREATE VIEW v_mapa_activo_macro AS
SELECT cod_activo,
       MODE() WITHIN GROUP (ORDER BY macroactivo_raw) AS macroactivo
FROM v_macro_base
WHERE cod_activo IS NOT NULL AND macroactivo_raw IS NOT NULL
GROUP BY cod_activo;

-- Banca y perfil más frecuentes por cliente (para rellenar vacíos)
CREATE VIEW v_mapa_cliente AS
SELECT id_sistema_cliente,
       MODE() WITHIN GROUP (ORDER BY cod_banca)
           FILTER (WHERE cod_banca IS NOT NULL)             AS cod_banca,
       MODE() WITHIN GROUP (ORDER BY cod_perfil_riesgo)
           FILTER (WHERE cod_perfil_riesgo IS NOT NULL)     AS cod_perfil_riesgo
FROM v_macro_base
WHERE id_sistema_cliente IS NOT NULL
GROUP BY id_sistema_cliente;

CREATE VIEW v_macro_limpio AS
WITH x AS (
    SELECT b.*,
           COALESCE(b.macroactivo_raw, m.macroactivo, 'SIN CLASIFICAR') AS macro_norm,
           COALESCE(b.cod_perfil_riesgo, c.cod_perfil_riesgo)           AS cod_perfil_final,
           COALESCE(b.cod_banca, c.cod_banca)                           AS cod_banca_final
    FROM v_macro_base b
    LEFT JOIN v_mapa_activo_macro m ON m.cod_activo = b.cod_activo
    LEFT JOIN v_mapa_cliente      c ON c.id_sistema_cliente = b.id_sistema_cliente
)
SELECT
    x.fecha_corte,
    x.id_sistema_cliente,
    x.id_corrupto,
    x.cod_activo,
    COALESCE(a.nombre_activo,
             CASE WHEN x.cod_activo IS NULL THEN 'SIN CÓDIGO DE ACTIVO'
                  ELSE 'ACTIVO NO CATALOGADO (' || x.cod_activo || ')' END) AS nombre_activo,
    (a.cod_activo IS NOT NULL)                                               AS activo_en_catalogo,
    CASE x.macro_norm
        WHEN 'FICS'           THEN 'FICs'
        WHEN 'RENTA VARIABLE' THEN 'Renta Variable'
        WHEN 'RENTA FIJA'     THEN 'Renta Fija'
        WHEN 'SIN CLASIFICAR' THEN 'Sin clasificar'
        ELSE INITCAP(x.macro_norm)
    END                                                                      AS macroactivo,
    x.saldo_cop,
    COALESCE(p.perfil_riesgo, 'NO REGISTRA')                                 AS perfil_riesgo,
    COALESCE(bn.banca, 'NO REGISTRA')                                        AS banca
FROM x
LEFT JOIN v_catalogo_activos  a  ON a.cod_activo = x.cod_activo
LEFT JOIN v_cat_perfil_riesgo p  ON p.cod_perfil_riesgo = x.cod_perfil_final
LEFT JOIN v_catalogo_banca    bn ON bn.cod_banca = x.cod_banca_final;

-- ---------------------------------------------------------------------
-- VISTA FINAL COP (histórica, consolidada). Excluye IDs corruptos,
-- fechas imposibles y saldos no interpretables.
-- ---------------------------------------------------------------------
CREATE VIEW vista_portafolio_cop AS
SELECT fecha_corte, id_sistema_cliente, id_corrupto AS id_aproximado,
       cod_activo, nombre_activo, macroactivo, perfil_riesgo, banca,
       SUM(saldo_cop) AS saldo_cop
FROM v_macro_limpio
WHERE id_sistema_cliente IS NOT NULL
  AND fecha_corte IS NOT NULL
  AND saldo_cop IS NOT NULL
GROUP BY fecha_corte, id_sistema_cliente, id_corrupto, cod_activo, nombre_activo,
         macroactivo, perfil_riesgo, banca;

-- Última fecha disponible POR CLIENTE
CREATE VIEW vista_portafolio_cop_ultimo AS
SELECT v.*
FROM vista_portafolio_cop v
JOIN (SELECT id_sistema_cliente, MAX(fecha_corte) AS ultima_fecha
      FROM vista_portafolio_cop GROUP BY id_sistema_cliente) u
  ON u.id_sistema_cliente = v.id_sistema_cliente
 AND u.ultima_fecha = v.fecha_corte;

-- ---------------------------------------------------------------------
-- USD
-- ---------------------------------------------------------------------
CREATE VIEW v_usd_limpio AS
SELECT DISTINCT
    fecha_segura(u.ingestion_year, u.ingestion_month, u.ingestion_day) AS fecha_corte,
    id_cliente_final(u.id_sistema_cliente)            AS id_sistema_cliente,
    id_es_notacion_cientifica(u.id_sistema_cliente)   AS id_corrupto,
    limpiar_texto(u.simbol)                           AS simbolo,
    limpiar_texto(u.cusip)                            AS cusip,
    limpiar_texto(u.isin)                             AS isin,
    REGEXP_REPLACE(COALESCE(limpiar_texto(u.nombre_activo), 'SIN NOMBRE'),
                   '\s+', ' ', 'g')                   AS nombre_activo,
    CASE
        WHEN UPPER(COALESCE(limpiar_texto(u.cusip), '')) = 'MONEYMKT'
          OR UPPER(COALESCE(limpiar_texto(u.isin), ''))  = 'LIQUIDEZ' THEN 'Liquidez'
        WHEN limpiar_texto(u.simbol) IS NULL                         THEN 'Fondo'
        ELSE 'Acción / ETF'
    END                                               AS tipo_activo,
    numero_seguro(u.cantidad)                         AS cantidad,
    numero_seguro(u.valor_mercado)                    AS saldo_usd,
    fecha_vencimiento_segura(u.fecha_vencimiento)     AS fecha_vencimiento,
    numero_seguro(u.tasa_cupon)                       AS tasa_cupon
FROM historico_aba_usd_internacional u;

CREATE VIEW vista_portafolio_usd AS
SELECT fecha_corte, id_sistema_cliente, id_corrupto AS id_aproximado,
       simbolo, cusip, isin, nombre_activo,
       tipo_activo, cantidad, saldo_usd, fecha_vencimiento, tasa_cupon
FROM v_usd_limpio
WHERE id_sistema_cliente IS NOT NULL
  AND fecha_corte IS NOT NULL
  AND saldo_usd IS NOT NULL;

CREATE VIEW vista_portafolio_usd_ultimo AS
SELECT v.*
FROM vista_portafolio_usd v
JOIN (SELECT id_sistema_cliente, MAX(fecha_corte) AS ultima_fecha
      FROM vista_portafolio_usd GROUP BY id_sistema_cliente) u
  ON u.id_sistema_cliente = v.id_sistema_cliente
 AND u.ultima_fecha = v.fecha_corte;
