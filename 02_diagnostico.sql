-- =====================================================================
-- 02_diagnostico.sql
-- Consultas para encontrar y cuantificar los problemas de calidad.
-- Ejecutar después de 00_funciones.sql y 01_vistas.sql
-- =====================================================================

-- 1. Conteo de filas crudas vs. filas que llegan a las vistas finales
SELECT 'macro crudo' AS fuente, COUNT(*) FROM historico_aba_macroactivos
UNION ALL SELECT 'macro v_macro_base (sin duplicados)', COUNT(*) FROM v_macro_base
UNION ALL SELECT 'macro vista final (agrupada)', COUNT(*) FROM vista_portafolio_cop
UNION ALL SELECT 'usd crudo', COUNT(*) FROM historico_aba_usd_internacional
UNION ALL SELECT 'usd vista final', COUNT(*) FROM vista_portafolio_usd;

-- 2. Vacíos / 'None' por columna (macro)
SELECT COUNT(*) AS total,
    COUNT(*) FILTER (WHERE limpiar_texto(ingestion_year)   IS NULL) AS sin_anio,
    COUNT(*) FILTER (WHERE limpiar_texto(ingestion_month)  IS NULL) AS sin_mes,
    COUNT(*) FILTER (WHERE limpiar_texto(ingestion_day)    IS NULL) AS sin_dia,
    COUNT(*) FILTER (WHERE limpiar_texto(id_sistema_cliente) IS NULL) AS sin_cliente,
    COUNT(*) FILTER (WHERE limpiar_texto(macroactivo)      IS NULL) AS sin_macroactivo,
    COUNT(*) FILTER (WHERE limpiar_texto(cod_activo)       IS NULL) AS sin_cod_activo,
    COUNT(*) FILTER (WHERE limpiar_texto(aba)              IS NULL) AS sin_saldo,
    COUNT(*) FILTER (WHERE limpiar_texto(cod_perfil_riesgo) IS NULL) AS sin_perfil,
    COUNT(*) FILTER (WHERE limpiar_texto(cod_banca)        IS NULL) AS sin_banca
FROM historico_aba_macroactivos;

-- 3. IDs en notación científica (irrecuperables) y cuántas filas afectan
SELECT id_sistema_cliente AS id_crudo, COUNT(*) AS filas
FROM historico_aba_macroactivos
WHERE id_es_notacion_cientifica(id_sistema_cliente)
GROUP BY 1 ORDER BY 2 DESC;

-- 4. Longitud de IDs en COP vs USD y traslape entre ambos
SELECT 'COP' AS fuente, LENGTH(id_cliente_texto(id_sistema_cliente)) AS largo, COUNT(*) AS filas
FROM historico_aba_macroactivos GROUP BY 2
UNION ALL
SELECT 'USD', LENGTH(id_cliente_texto(id_sistema_cliente)), COUNT(*)
FROM historico_aba_usd_internacional GROUP BY 2
ORDER BY 1, 2;

SELECT
    (SELECT COUNT(DISTINCT id_sistema_cliente) FROM vista_portafolio_cop) AS clientes_cop,
    (SELECT COUNT(DISTINCT id_sistema_cliente) FROM vista_portafolio_usd) AS clientes_usd,
    (SELECT COUNT(*) FROM (SELECT id_sistema_cliente FROM vista_portafolio_cop
                           INTERSECT
                           SELECT id_sistema_cliente FROM vista_portafolio_usd) t) AS clientes_en_ambos;

-- 5. Códigos de activo que no existen en el catálogo (tras correcciones)
SELECT b.cod_activo, COUNT(*) AS filas, SUM(b.saldo_cop) AS saldo_total
FROM v_macro_base b
LEFT JOIN v_catalogo_activos a ON a.cod_activo = b.cod_activo
WHERE a.cod_activo IS NULL
GROUP BY 1 ORDER BY 2 DESC;

-- 6. Duplicados en catálogos (causan multiplicación de filas en JOIN)
SELECT 'catalogo_banca' AS tabla, cod_banca AS codigo, COUNT(*) AS veces
FROM catalogo_banca GROUP BY 2 HAVING COUNT(*) > 1
UNION ALL
SELECT 'catalogo_activos', cod_activo, COUNT(*)
FROM catalogo_activos GROUP BY 2 HAVING COUNT(*) > 1
UNION ALL
SELECT 'cat_perfil_riesgo', cod_perfil_riesgo, COUNT(*)
FROM cat_perfil_riesgo GROUP BY 2 HAVING COUNT(*) > 1;

-- 7. Saldos no interpretables (hay texto pero no se pudo convertir)
SELECT aba, COUNT(*) FROM historico_aba_macroactivos
WHERE limpiar_texto(aba) IS NOT NULL AND numero_seguro(aba) IS NULL
GROUP BY 1;

SELECT valor_mercado, COUNT(*) FROM historico_aba_usd_internacional
WHERE limpiar_texto(valor_mercado) IS NOT NULL AND numero_seguro(valor_mercado) IS NULL
GROUP BY 1;

-- 8. Filas con fecha imposible de reconstruir
SELECT ingestion_year, ingestion_month, ingestion_day, "year", "month", COUNT(*) AS filas
FROM historico_aba_macroactivos
WHERE fecha_segura(
        COALESCE(limpiar_texto(ingestion_year),  limpiar_texto("year")),
        COALESCE(limpiar_texto(ingestion_month), limpiar_texto("month")),
        ingestion_day) IS NULL
GROUP BY 1,2,3,4,5 ORDER BY 6 DESC;

-- 9. Duplicados exactos de ingestión
SELECT
  (SELECT COUNT(*) FROM historico_aba_macroactivos)
- (SELECT COUNT(*) FROM (SELECT DISTINCT * FROM historico_aba_macroactivos) d) AS dup_macro,
  (SELECT COUNT(*) FROM historico_aba_usd_internacional)
- (SELECT COUNT(*) FROM (SELECT DISTINCT * FROM historico_aba_usd_internacional) d) AS dup_usd;

-- 10. Códigos de perfil / banca que no están en catálogo
SELECT 'perfil' AS tipo, b.cod_perfil_riesgo AS codigo, COUNT(*) AS filas
FROM v_macro_base b
LEFT JOIN v_cat_perfil_riesgo p ON p.cod_perfil_riesgo = b.cod_perfil_riesgo
WHERE b.cod_perfil_riesgo IS NOT NULL AND p.cod_perfil_riesgo IS NULL GROUP BY 2
UNION ALL
SELECT 'banca', b.cod_banca, COUNT(*)
FROM v_macro_base b
LEFT JOIN v_catalogo_banca c ON c.cod_banca = b.cod_banca
WHERE b.cod_banca IS NOT NULL AND c.cod_banca IS NULL GROUP BY 2;

-- 11. Activos con macroactivo inconsistente entre filas
SELECT cod_activo, ARRAY_AGG(DISTINCT macroactivo_raw) AS macros
FROM v_macro_base
WHERE cod_activo IS NOT NULL AND macroactivo_raw IS NOT NULL
GROUP BY 1 HAVING COUNT(DISTINCT macroactivo_raw) > 1;

-- 12. Clientes cuyos activos están en fechas distintas (afecta "última fecha")
SELECT id_sistema_cliente, COUNT(DISTINCT fecha_corte) AS fechas, MIN(fecha_corte), MAX(fecha_corte)
FROM vista_portafolio_cop
GROUP BY 1 ORDER BY 2 DESC LIMIT 20;

-- 13. USD: placeholders de fecha de vencimiento y tipos de activo
SELECT fecha_vencimiento AS crudo, COUNT(*) FROM historico_aba_usd_internacional GROUP BY 1 ORDER BY 2 DESC;
SELECT tipo_activo, COUNT(*), SUM(saldo_usd) FROM vista_portafolio_usd GROUP BY 1;