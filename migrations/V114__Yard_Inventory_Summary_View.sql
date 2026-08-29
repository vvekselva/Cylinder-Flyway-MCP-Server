-- ============================================================================
-- V114__Yard_Inventory_Summary_View.sql
--
-- Purpose:
-- Quick lookup summary of cylinders currently present in yard inventory.
--
-- IMPORTANT:
-- Uses Yard Inventory as source of truth.
-- Does NOT use tbl_cylinder_current_status.
-- ============================================================================

DROP VIEW IF EXISTS public.vw_yard_inventory_summary;

CREATE VIEW public.vw_yard_inventory_summary AS
SELECT
    yi.pk_yard_inventory_id,
    yi.yard_code,
    yi.yard_name,

    p.pk_product_id,
    p.product_name,

    cs.pk_cylinder_state_id,
    cs.cylinder_state,

    COUNT(yil.pk_yard_inventory_line_id) AS cylinder_count

FROM public.tbl_yard_inventory_line yil

INNER JOIN public.tbl_yard_inventory yi
    ON yi.pk_yard_inventory_id = yil.fk_yard_inventory

INNER JOIN public.tbl_cylinder c
    ON c.pk_cylinder_id = yil.fk_cylinder

INNER JOIN public.tbl_product p
    ON p.pk_product_id = c.fk_product

INNER JOIN public.tbl_cylinder_states cs
    ON cs.pk_cylinder_state_id = yil.fk_cylinder_state

WHERE yil.is_active = TRUE

GROUP BY
    yi.pk_yard_inventory_id,
    yi.yard_code,
    yi.yard_name,

    p.pk_product_id,
    p.product_name,

    cs.pk_cylinder_state_id,
    cs.cylinder_state;