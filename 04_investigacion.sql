-- =====================================================================
-- 04_investigacion.sql
-- Investiga: IDs científicos, duplicados y IDs con typos.
-- =====================================================================

-- 1. ¿Cuántos tokens científicos distintos hay y cuánto pesa cada uno?
--    Si filas >> combinaciones, un mismo token agrupa a VARIOS clientes.
SELECT id_sistema_cliente AS token_expandido,
       COUNT(*)                                     AS filas,
       COUNT(DISTINCT (fecha_corte, cod_activo))    AS combinaciones_fecha_activo,
       COUNT(DISTINCT fecha_corte)                  AS fechas,
       SUM(saldo_cop)                               AS saldo
FROM v_macro_base
WHERE id_corrupto
GROUP BY 1
ORDER BY saldo DESC NULLS LAST;

-- 2. ¿Los "duplicados" eliminados son duplicados exactos del crudo?
--    Si filas_crudas - distintas_crudas es mucho menor que
--    filas_crudas - filas_base, mi DISTINCT está fusionando filas legítimas.
SELECT
  (SELECT COUNT(*) FROM historico_aba_macroactivos)                                   AS filas_crudas,
  (SELECT COUNT(*) FROM (SELECT DISTINCT * FROM historico_aba_macroactivos) d)        AS distintas_crudas,
  (SELECT COUNT(*) FROM v_macro_base)                                                 AS filas_base;

SELECT
  (SELECT COUNT(*) FROM historico_aba_usd_internacional)                              AS filas_crudas_usd,
  (SELECT COUNT(*) FROM (SELECT DISTINCT * FROM historico_aba_usd_internacional) d)   AS distintas_crudas_usd,
  (SELECT COUNT(*) FROM v_usd_limpio)                                                 AS filas_base_usd;

-- 2b. Misma clave (fecha, cliente, activo) con saldos DISTINTOS
--     (si da 0, los duplicados eran copias idénticas)
SELECT COUNT(*) AS claves_con_varios_saldos
FROM (SELECT 1 FROM v_macro_base
      WHERE NOT id_corrupto AND id_sistema_cliente IS NOT NULL
      GROUP BY fecha_corte, id_sistema_cliente, cod_activo
      HAVING COUNT(*) > 1) t;

-- 3. IDs con largo atípico (los 8 de la prueba F6)
SELECT id_sistema_cliente, LENGTH(id_sistema_cliente) AS largo, COUNT(*) AS filas,
       MIN(fecha_corte) AS desde, MAX(fecha_corte) AS hasta, SUM(saldo_cop) AS saldo
FROM vista_portafolio_cop
WHERE LENGTH(id_sistema_cliente) NOT IN (10, 11)
GROUP BY 1 ORDER BY 3 DESC;

-- 4. IDs sospechosos de typo: a 1 edición de distancia de un ID mucho más frecuente
CREATE EXTENSION IF NOT EXISTS fuzzystrmatch;

WITH ids AS (
    SELECT id_sistema_cliente AS id, COUNT(*) AS n,
           MIN(fecha_corte) AS desde, MAX(fecha_corte) AS hasta
    FROM v_macro_base
    WHERE NOT id_corrupto AND id_sistema_cliente IS NOT NULL
    GROUP BY 1
)
SELECT a.id AS id_sospechoso, a.n AS filas_sospechoso, a.desde, a.hasta,
       b.id AS id_candidato,  b.n AS filas_candidato
FROM ids a
JOIN ids b ON a.id <> b.id AND a.n < b.n AND levenshtein(a.id, b.id) = 1
ORDER BY a.n DESC;

-- 5. ¿Los IDs con typo aparecen también en USD? (cruce COP-USD)
SELECT id_sistema_cliente FROM vista_portafolio_usd
INTERSECT
SELECT id_sistema_cliente FROM vista_portafolio_cop;