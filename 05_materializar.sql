-- =====================================================================
-- 05_materializar.sql
-- Guarda el resultado final de las vistas "ultimo" (rápido para Django).
-- Ejecutar DESPUÉS de 01_vistas.sql. Si recargas datos o cambias 01,
-- vuelve a correr 01 y luego este archivo (o usa REFRESH MATERIALIZED VIEW).
-- =====================================================================
-- PostgreSQL 17+: CREATE/REFRESH MATERIALIZED VIEW corren con search_path
-- restringido, así que las funciones deben fijar el suyo para encontrarse entre sí.
DO $$
DECLARE r RECORD;
BEGIN
    FOR r IN
        SELECT p.oid::regprocedure AS firma
        FROM pg_proc p
        JOIN pg_language l ON l.oid = p.prolang
        WHERE p.pronamespace = 'public'::regnamespace
          AND l.lanname IN ('sql', 'plpgsql')
    LOOP
        EXECUTE format('ALTER FUNCTION %s SET search_path = public, pg_catalog', r.firma);
    END LOOP;
END $$;

DROP MATERIALIZED VIEW IF EXISTS mv_portafolio_cop_ultimo;
DROP MATERIALIZED VIEW IF EXISTS mv_portafolio_usd_ultimo;

CREATE MATERIALIZED VIEW mv_portafolio_cop_ultimo AS SELECT * FROM vista_portafolio_cop_ultimo;
CREATE MATERIALIZED VIEW mv_portafolio_usd_ultimo AS SELECT * FROM vista_portafolio_usd_ultimo;

CREATE INDEX idx_mv_cop_cliente ON mv_portafolio_cop_ultimo (id_sistema_cliente);
CREATE INDEX idx_mv_usd_cliente ON mv_portafolio_usd_ultimo (id_sistema_cliente);
ANALYZE mv_portafolio_cop_ultimo;
ANALYZE mv_portafolio_usd_ultimo;