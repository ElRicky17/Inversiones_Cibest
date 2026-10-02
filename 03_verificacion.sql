-- =====================================================================
-- 03_verificacion.sql
-- Cada bloque indica el resultado esperado.
-- =====================================================================

-- ---------------------------------------------------------------------
-- A. CUADRE DE SALDOS COP
-- Esperado: diferencia_cuadre = 0
--   crudo - duplicados = final + excluidos
-- ---------------------------------------------------------------------
SELECT
    crudo,
    dedup,
    crudo - dedup                      AS saldo_en_duplicados,
    excluidos,
    final,
    dedup - (final + excluidos)        AS diferencia_cuadre   -- debe ser 0
FROM (
    SELECT
        (SELECT SUM(numero_seguro(aba)) FROM historico_aba_macroactivos)  AS crudo,
        (SELECT SUM(saldo_cop) FROM v_macro_base)                          AS dedup,
        (SELECT SUM(saldo_cop) FROM v_macro_limpio
          WHERE NOT (id_sistema_cliente IS NOT NULL
                     AND fecha_corte IS NOT NULL AND saldo_cop IS NOT NULL)) AS excluidos,
        (SELECT SUM(saldo_cop) FROM vista_portafolio_cop)                  AS final
) t;

-- Detalle de lo excluido (para poder explicarlo en la presentación)
SELECT
    CASE WHEN id_sistema_cliente IS NULL THEN 'sin id'
         WHEN fecha_corte IS NULL       THEN 'fecha irrecuperable'
         WHEN saldo_cop IS NULL         THEN 'saldo no interpretable' END AS motivo,
    COUNT(*) AS filas, SUM(saldo_cop) AS saldo
FROM v_macro_limpio
WHERE NOT (id_sistema_cliente IS NOT NULL
           AND fecha_corte IS NOT NULL AND saldo_cop IS NOT NULL)
GROUP BY 1;

-- ---------------------------------------------------------------------
-- B. LOS JOIN NO MULTIPLICAN FILAS (bug de PR duplicado)
-- Esperado: ambos conteos iguales
-- ---------------------------------------------------------------------
SELECT (SELECT COUNT(*) FROM v_macro_base)   AS filas_base,
       (SELECT COUNT(*) FROM v_macro_limpio) AS filas_limpio;

-- ---------------------------------------------------------------------
-- C. VISTAS FINALES SIN NULOS EN CAMPOS CLAVE
-- Esperado: todo 0
-- ---------------------------------------------------------------------
SELECT
    COUNT(*) FILTER (WHERE fecha_corte IS NULL)        AS sin_fecha,
    COUNT(*) FILTER (WHERE id_sistema_cliente IS NULL) AS sin_cliente,
    COUNT(*) FILTER (WHERE saldo_cop IS NULL)          AS sin_saldo,
    COUNT(*) FILTER (WHERE macroactivo IS NULL)        AS sin_macro,
    COUNT(*) FILTER (WHERE id_sistema_cliente !~ '^(SCI-)?[0-9]+$') AS id_formato_raro
FROM vista_portafolio_cop;

-- ---------------------------------------------------------------------
-- D. "ÚLTIMA FECHA": una sola fecha por cliente
-- Esperado: 0 filas
-- ---------------------------------------------------------------------
SELECT id_sistema_cliente, COUNT(DISTINCT fecha_corte) AS fechas
FROM vista_portafolio_cop_ultimo
GROUP BY 1 HAVING COUNT(DISTINCT fecha_corte) > 1;

SELECT id_sistema_cliente, COUNT(DISTINCT fecha_corte) AS fechas
FROM vista_portafolio_usd_ultimo
GROUP BY 1 HAVING COUNT(DISTINCT fecha_corte) > 1;

-- ---------------------------------------------------------------------
-- E. VALORES CATEGÓRICOS NORMALIZADOS (sin variantes raras)
-- Esperado: macroactivo ~ FICs / Renta Fija / Renta Variable / Sin clasificar
--           perfil: AGRESIVO, MODERADO, CONSERVADOR, SIN DEFINIR, NO REGISTRA
--           banca: Privada, Personal, Preferencial, Empresas, Pymes, NO REGISTRA
-- ---------------------------------------------------------------------
SELECT 'macroactivo' AS campo, macroactivo AS valor, COUNT(*) AS filas FROM vista_portafolio_cop GROUP BY 2
UNION ALL SELECT 'perfil', perfil_riesgo, COUNT(*) FROM vista_portafolio_cop GROUP BY 2
UNION ALL SELECT 'banca',  banca,         COUNT(*) FROM vista_portafolio_cop GROUP BY 2
ORDER BY 1, 3 DESC;

-- ---------------------------------------------------------------------
-- F. PRUEBAS PUNTUALES con filas que viste en tus capturas
-- ---------------------------------------------------------------------
-- F1. Cliente 10020203023, 2024-01-04, activo 1000:
--     esperado saldo 366756000, Renta Fija, MODERADO, Privada
-- F2. Mismo cliente, 2024-02-01, antes 'None': esperado 'SIN CÓDIGO DE ACTIVO', FICs, 445708066
-- F3. Cliente 10098522488, mes vacío: esperado fecha_corte 2024-03-27 (mes recuperado de la col. final)
-- F4. Cliente 10032184607, 2024-04-15, activo 1022: esperado 'ACTIVO NO CATALOGADO (1022)'
--     y banca Personal (rellenada desde otras filas del cliente)
-- F5. Cliente 10071747544, 2023-11-27: esperado cod_activo 1007 (corregido desde 10007), Fiducuenta, AGRESIVO
SELECT fecha_corte, id_sistema_cliente, cod_activo, nombre_activo,
       macroactivo, perfil_riesgo, banca, saldo_cop
FROM vista_portafolio_cop
WHERE (id_sistema_cliente = '10020203023' AND fecha_corte IN ('2024-01-04','2024-02-01'))
   OR (id_sistema_cliente = '10098522488' AND fecha_corte = '2024-03-27')
   OR (id_sistema_cliente = '10032184607' AND fecha_corte = '2024-04-15' AND cod_activo = '1022')
   OR (id_sistema_cliente = '10071747544' AND fecha_corte = '2023-11-27')
ORDER BY id_sistema_cliente, fecha_corte;

-- F6. Esperado: ids_cortos = 0 y tokens_cientificos = 11 (clientes SCI-... incluidos y marcados)
SELECT COUNT(DISTINCT id_sistema_cliente) FILTER (WHERE LENGTH(id_sistema_cliente) < 9) AS ids_cortos,
       COUNT(DISTINCT id_sistema_cliente) FILTER (WHERE id_aproximado)                  AS tokens_cientificos
FROM vista_portafolio_cop;

-- F7. El typo 1002203023 ya no debe existir y debe haberse sumado a 10020203023 (esperado 0 filas)
SELECT * FROM vista_portafolio_cop WHERE id_sistema_cliente = '1002203023';

-- ---------------------------------------------------------------------
-- G. USD
-- ---------------------------------------------------------------------
-- G1. Cuadre. Esperado: diferencia = 0
SELECT crudo, dedup, excluidos, final, dedup - (final + excluidos) AS diferencia
FROM (
    SELECT
      (SELECT SUM(numero_seguro(valor_mercado)) FROM historico_aba_usd_internacional) AS crudo,
      (SELECT SUM(saldo_usd) FROM v_usd_limpio) AS dedup,
      (SELECT SUM(saldo_usd) FROM v_usd_limpio
        WHERE NOT (id_sistema_cliente IS NOT NULL
                   AND fecha_corte IS NOT NULL AND saldo_usd IS NOT NULL)) AS excluidos,
      (SELECT SUM(saldo_usd) FROM vista_portafolio_usd) AS final
) t;

-- G2. Cliente 1004870235, 2024-04-26: esperado AMZN 100 acciones = 17659 USD,
--     nombres sin espacios sobrantes, fecha_vencimiento NULL (no 1900)
SELECT fecha_corte, simbolo, nombre_activo, tipo_activo, cantidad, saldo_usd, fecha_vencimiento
FROM vista_portafolio_usd
WHERE id_sistema_cliente = '1004870235' AND fecha_corte = '2024-04-26'
ORDER BY saldo_usd DESC;

-- G3. Esperado: 0 filas con fecha de vencimiento 1900 y nombres con espacios dobles/bordes
SELECT COUNT(*) FILTER (WHERE fecha_vencimiento < '1950-01-01')      AS venc_1900,
       COUNT(*) FILTER (WHERE nombre_activo <> BTRIM(nombre_activo)
                           OR nombre_activo ~ '\s{2,}')              AS nombres_sucios
FROM vista_portafolio_usd;

-- ---------------------------------------------------------------------
-- H. PRUEBA DE CONSUMO (lo que usará Django)
-- ---------------------------------------------------------------------
SELECT id_sistema_cliente, MAX(fecha_corte) AS ultima_fecha, SUM(saldo_cop) AS total_cop
FROM vista_portafolio_cop_ultimo GROUP BY 1 ORDER BY 3 DESC LIMIT 10;

-- ---------------------------------------------------------------------
-- I. IDs descartados por largo < 9: ver cómo venían en el crudo
-- ---------------------------------------------------------------------
SELECT id_sistema_cliente AS id_crudo, COUNT(*) AS filas, SUM(numero_seguro(aba)) AS saldo
FROM historico_aba_macroactivos
WHERE id_cliente_texto(id_sistema_cliente) IS NOT NULL
  AND LENGTH(id_cliente_texto(id_sistema_cliente)) < 9
GROUP BY 1;

-- J. Filas con ID mal formado en el crudo (texto pegado al ID). Revisar a mano:
SELECT * FROM historico_aba_macroactivos
WHERE id_sistema_cliente ~ '^100($|[A-Za-z])';