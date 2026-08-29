-- =============================================================================
-- V142__Summary_Metric_Lookup_Refresh_Triggers.sql
-- =============================================================================
-- PURPOSE
--   Keep tbl_summary_metric_lookup updated from the database trigger chain.
--
-- BACKGROUND
--   V141 created tbl_summary_metric_lookup and fn_refresh_summary_metric_lookup().
--   This migration attaches refresh triggers to the source tables that affect the
--   currently defined summary metrics.
--
-- SOURCE TABLES COVERED
--   1. tbl_challan_book_registry
--      - total books
--      - active books
--      - closed books
--      - book-type counts
--      - active book-type counts
--      - active/closed location changes
--
--   2. tbl_challan_page_audit_ledger
--      - unused pages in active delivery books
--      - unused pages in active empty pickup books
--      - unused pages in active supplier empty drop-off books
--
--   3. tbl_customer
--      - total customers
--      - active customers
--      - GST / non-GST customer split
--      - active GST / active non-GST split
--
--   4. tbl_supplier
--      - total suppliers
--      - active suppliers
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_refresh_summary_metric_lookup_trigger()
RETURNS TRIGGER AS $$
BEGIN
    PERFORM public.fn_refresh_summary_metric_lookup();

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.fn_refresh_summary_metric_lookup_trigger() IS
    'Refreshes summary metric lookup values after source-table changes.';


-- -----------------------------------------------------------------------------
-- Challan book registry source metrics
-- -----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_summary_metric_refresh_challan_book_registry
    ON public.tbl_challan_book_registry;

CREATE TRIGGER trg_summary_metric_refresh_challan_book_registry
AFTER INSERT OR UPDATE OR DELETE ON public.tbl_challan_book_registry
FOR EACH ROW
EXECUTE FUNCTION public.fn_refresh_summary_metric_lookup_trigger();

COMMENT ON TRIGGER trg_summary_metric_refresh_challan_book_registry
ON public.tbl_challan_book_registry IS
    'Refreshes summary metric lookup after challan book registry changes.';


-- -----------------------------------------------------------------------------
-- Challan page ledger source metrics
-- -----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_summary_metric_refresh_challan_page_audit_ledger
    ON public.tbl_challan_page_audit_ledger;

CREATE TRIGGER trg_summary_metric_refresh_challan_page_audit_ledger
AFTER INSERT OR UPDATE OR DELETE ON public.tbl_challan_page_audit_ledger
FOR EACH ROW
EXECUTE FUNCTION public.fn_refresh_summary_metric_lookup_trigger();

COMMENT ON TRIGGER trg_summary_metric_refresh_challan_page_audit_ledger
ON public.tbl_challan_page_audit_ledger IS
    'Refreshes summary metric lookup after challan page status/page ledger changes.';


-- -----------------------------------------------------------------------------
-- Customer source metrics
-- -----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_summary_metric_refresh_customer
    ON public.tbl_customer;

CREATE TRIGGER trg_summary_metric_refresh_customer
AFTER INSERT OR UPDATE OR DELETE ON public.tbl_customer
FOR EACH ROW
EXECUTE FUNCTION public.fn_refresh_summary_metric_lookup_trigger();

COMMENT ON TRIGGER trg_summary_metric_refresh_customer
ON public.tbl_customer IS
    'Refreshes summary metric lookup after customer active/GST changes.';


-- -----------------------------------------------------------------------------
-- Supplier source metrics
-- -----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_summary_metric_refresh_supplier
    ON public.tbl_supplier;

CREATE TRIGGER trg_summary_metric_refresh_supplier
AFTER INSERT OR UPDATE OR DELETE ON public.tbl_supplier
FOR EACH ROW
EXECUTE FUNCTION public.fn_refresh_summary_metric_lookup_trigger();

COMMENT ON TRIGGER trg_summary_metric_refresh_supplier
ON public.tbl_supplier IS
    'Refreshes summary metric lookup after supplier active-status changes.';


-- Initial refresh after installing trigger chain.
SELECT public.fn_refresh_summary_metric_lookup();
