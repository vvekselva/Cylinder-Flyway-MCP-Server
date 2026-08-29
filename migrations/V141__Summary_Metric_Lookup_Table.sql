-- =============================================================================
-- V141__Summary_Metric_Lookup_Table.sql
-- =============================================================================
-- PURPOSE
--   Store dashboard/summary metric values in a reusable lookup-style table.
--   The value column is numeric so both whole-number counts and decimal metrics
--   can be represented.
--
-- REQUIRED FIVE COLUMNS
--   1. primary key  -> pk_summary_metric_lookup_id
--   2. look_up_key
--   3. ui_label_for_the_lookup_field
--   4. actual meaning -> actual_meaning
--   5. value
-- =============================================================================

CREATE SEQUENCE IF NOT EXISTS public.pk_summary_metric_lookup_id_serial
    INCREMENT BY 1 MINVALUE 1 START 1 CACHE 1 NO CYCLE;

CREATE TABLE IF NOT EXISTS public.tbl_summary_metric_lookup (
    pk_summary_metric_lookup_id      int8          NOT NULL DEFAULT nextval('public.pk_summary_metric_lookup_id_serial'),
    look_up_key                      varchar(120)  NOT NULL,
    ui_label_for_the_lookup_field    varchar(250)  NOT NULL,
    actual_meaning                   varchar(1000) NOT NULL,
    value                            numeric(20,4) NOT NULL DEFAULT 0,

    CONSTRAINT tbl_summary_metric_lookup_pk PRIMARY KEY (pk_summary_metric_lookup_id),
    CONSTRAINT tbl_summary_metric_lookup_key_uk UNIQUE (look_up_key)
);

COMMENT ON TABLE public.tbl_summary_metric_lookup IS
    'Reusable lookup table for numeric summary/dashboard metrics shown in UI boxes.';

CREATE INDEX IF NOT EXISTS idx_summary_metric_lookup_key
    ON public.tbl_summary_metric_lookup(look_up_key);

CREATE OR REPLACE FUNCTION public.fn_seed_summary_metric_lookup()
RETURNS void AS $$
BEGIN
    INSERT INTO public.tbl_summary_metric_lookup
        (look_up_key, ui_label_for_the_lookup_field, actual_meaning, value)
    VALUES
        ('TOTAL_CHALLAN_BOOKS', 'Total Challan Books', 'Total number of challan books registered in the system.', 0),
        ('TOTAL_ACTIVE_BOOKS', 'Active Books', 'Total number of challan books that are not exhausted or archived.', 0),
        ('TOTAL_CLOSED_BOOKS', 'Closed Books', 'Total number of challan books with current location EXHAUSTED_ARCHIVED.', 0),
        ('TOTAL_DELIVERY_CHALLAN_BOOKS', 'Delivery Challan Books', 'Total number of books of type DELIVERY_CHALLAN.', 0),
        ('TOTAL_EMPTY_PICKUP_BOOKS', 'Empty Pickup Books', 'Total number of books of type EMPTY_PICKUP_CHALLAN.', 0),
        ('TOTAL_SUPPLIER_EMPTY_BOOKS', 'Supplier Empty Drop-off Books', 'Total number of supplier empty drop-off books. This maps to book type FILLING_NOTE.', 0),
        ('TOTAL_ACTIVE_DELIVERY_CHALLAN_BOOKS', 'Active Delivery Challan Books', 'Total active books of type DELIVERY_CHALLAN.', 0),
        ('TOTAL_ACTIVE_EMPTY_PICKUP_BOOKS', 'Active Empty Pickup Books', 'Total active books of type EMPTY_PICKUP_CHALLAN.', 0),
        ('TOTAL_ACTIVE_SUPPLIER_EMPTY_DROPOFF_BOOKS', 'Active Supplier Empty Drop-off Books', 'Total active supplier empty drop-off books. This maps to book type FILLING_NOTE.', 0),
        ('TOTAL_UNUSED_PAGES_ACTIVE_DELIVERY_CHALLAN_BOOKS', 'Unused Pages in Active Delivery Books', 'Total UNUSED pages in active DELIVERY_CHALLAN books.', 0),
        ('TOTAL_UNUSED_PAGES_ACTIVE_EMPTY_PICKUP_BOOKS', 'Unused Pages in Active Empty Pickup Books', 'Total UNUSED pages in active EMPTY_PICKUP_CHALLAN books.', 0),
        ('TOTAL_UNUSED_PAGES_ACTIVE_SUPPLIER_EMPTY_DROPOFF_BOOKS', 'Unused Pages in Active Supplier Empty Drop-off Books', 'Total UNUSED pages in active FILLING_NOTE books.', 0),
        ('TOTAL_CUSTOMERS', 'Total Customers', 'Total number of customers in the system.', 0),
        ('TOTAL_ACTIVE_CUSTOMERS', 'Active Customers', 'Total number of active customers.', 0),
        ('TOTAL_CUSTOMERS_WITH_GST_NUMBER', 'Customers With GST Number', 'Total number of customers where GST number is present and not blank.', 0),
        ('TOTAL_CUSTOMERS_WITHOUT_GST_NUMBER', 'Customers Without GST Number', 'Total number of customers where GST number is absent or blank.', 0),
        ('TOTAL_ACTIVE_CUSTOMERS_WITH_GST_NUMBER', 'Active Customers With GST Number', 'Total active customers where GST number is present and not blank.', 0),
        ('TOTAL_ACTIVE_CUSTOMERS_WITHOUT_GST_NUMBER', 'Active Customers Without GST Number', 'Total active customers where GST number is absent or blank.', 0),
        ('TOTAL_SUPPLIERS', 'Total Suppliers', 'Total number of suppliers in the system.', 0),
        ('TOTAL_ACTIVE_SUPPLIERS', 'Active Suppliers', 'Total number of active suppliers.', 0)
    ON CONFLICT (look_up_key) DO UPDATE
       SET ui_label_for_the_lookup_field = EXCLUDED.ui_label_for_the_lookup_field,
           actual_meaning = EXCLUDED.actual_meaning;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION public.fn_refresh_summary_metric_lookup()
RETURNS int4 AS $$
DECLARE
    v_updated int4;
BEGIN
    PERFORM public.fn_seed_summary_metric_lookup();

    WITH metric_values AS (
        SELECT 'TOTAL_CHALLAN_BOOKS'::varchar AS look_up_key, COUNT(*)::numeric(20,4) AS metric_value
          FROM public.tbl_challan_book_registry
        UNION ALL
        SELECT 'TOTAL_ACTIVE_BOOKS', COUNT(*)::numeric(20,4)
          FROM public.tbl_challan_book_registry
         WHERE current_location::text <> 'EXHAUSTED_ARCHIVED'
        UNION ALL
        SELECT 'TOTAL_CLOSED_BOOKS', COUNT(*)::numeric(20,4)
          FROM public.tbl_challan_book_registry
         WHERE current_location::text = 'EXHAUSTED_ARCHIVED'
        UNION ALL
        SELECT 'TOTAL_DELIVERY_CHALLAN_BOOKS', COUNT(*)::numeric(20,4)
          FROM public.tbl_challan_book_registry
         WHERE book_type::text = 'DELIVERY_CHALLAN'
        UNION ALL
        SELECT 'TOTAL_EMPTY_PICKUP_BOOKS', COUNT(*)::numeric(20,4)
          FROM public.tbl_challan_book_registry
         WHERE book_type::text = 'EMPTY_PICKUP_CHALLAN'
        UNION ALL
        SELECT 'TOTAL_SUPPLIER_EMPTY_BOOKS', COUNT(*)::numeric(20,4)
          FROM public.tbl_challan_book_registry
         WHERE book_type::text = 'FILLING_NOTE'
        UNION ALL
        SELECT 'TOTAL_ACTIVE_DELIVERY_CHALLAN_BOOKS', COUNT(*)::numeric(20,4)
          FROM public.tbl_challan_book_registry
         WHERE book_type::text = 'DELIVERY_CHALLAN'
           AND current_location::text <> 'EXHAUSTED_ARCHIVED'
        UNION ALL
        SELECT 'TOTAL_ACTIVE_EMPTY_PICKUP_BOOKS', COUNT(*)::numeric(20,4)
          FROM public.tbl_challan_book_registry
         WHERE book_type::text = 'EMPTY_PICKUP_CHALLAN'
           AND current_location::text <> 'EXHAUSTED_ARCHIVED'
        UNION ALL
        SELECT 'TOTAL_ACTIVE_SUPPLIER_EMPTY_DROPOFF_BOOKS', COUNT(*)::numeric(20,4)
          FROM public.tbl_challan_book_registry
         WHERE book_type::text = 'FILLING_NOTE'
           AND current_location::text <> 'EXHAUSTED_ARCHIVED'
        UNION ALL
        SELECT 'TOTAL_UNUSED_PAGES_ACTIVE_DELIVERY_CHALLAN_BOOKS', COUNT(*)::numeric(20,4)
          FROM public.tbl_challan_page_audit_ledger ledger
          JOIN public.tbl_challan_book_registry book
            ON book.pk_book_id = ledger.fk_book_id
         WHERE book.book_type::text = 'DELIVERY_CHALLAN'
           AND book.current_location::text <> 'EXHAUSTED_ARCHIVED'
           AND ledger.page_status::text = 'UNUSED'
        UNION ALL
        SELECT 'TOTAL_UNUSED_PAGES_ACTIVE_EMPTY_PICKUP_BOOKS', COUNT(*)::numeric(20,4)
          FROM public.tbl_challan_page_audit_ledger ledger
          JOIN public.tbl_challan_book_registry book
            ON book.pk_book_id = ledger.fk_book_id
         WHERE book.book_type::text = 'EMPTY_PICKUP_CHALLAN'
           AND book.current_location::text <> 'EXHAUSTED_ARCHIVED'
           AND ledger.page_status::text = 'UNUSED'
        UNION ALL
        SELECT 'TOTAL_UNUSED_PAGES_ACTIVE_SUPPLIER_EMPTY_DROPOFF_BOOKS', COUNT(*)::numeric(20,4)
          FROM public.tbl_challan_page_audit_ledger ledger
          JOIN public.tbl_challan_book_registry book
            ON book.pk_book_id = ledger.fk_book_id
         WHERE book.book_type::text = 'FILLING_NOTE'
           AND book.current_location::text <> 'EXHAUSTED_ARCHIVED'
           AND ledger.page_status::text = 'UNUSED'
        UNION ALL
        SELECT 'TOTAL_CUSTOMERS', COUNT(*)::numeric(20,4)
          FROM public.tbl_customer
        UNION ALL
        SELECT 'TOTAL_ACTIVE_CUSTOMERS', COUNT(*)::numeric(20,4)
          FROM public.tbl_customer
         WHERE active = true
        UNION ALL
        SELECT 'TOTAL_CUSTOMERS_WITH_GST_NUMBER', COUNT(*)::numeric(20,4)
          FROM public.tbl_customer
         WHERE gst_number IS NOT NULL AND btrim(gst_number) <> ''
        UNION ALL
        SELECT 'TOTAL_CUSTOMERS_WITHOUT_GST_NUMBER', COUNT(*)::numeric(20,4)
          FROM public.tbl_customer
         WHERE gst_number IS NULL OR btrim(gst_number) = ''
        UNION ALL
        SELECT 'TOTAL_ACTIVE_CUSTOMERS_WITH_GST_NUMBER', COUNT(*)::numeric(20,4)
          FROM public.tbl_customer
         WHERE active = true
           AND gst_number IS NOT NULL AND btrim(gst_number) <> ''
        UNION ALL
        SELECT 'TOTAL_ACTIVE_CUSTOMERS_WITHOUT_GST_NUMBER', COUNT(*)::numeric(20,4)
          FROM public.tbl_customer
         WHERE active = true
           AND (gst_number IS NULL OR btrim(gst_number) = '')
        UNION ALL
        SELECT 'TOTAL_SUPPLIERS', COUNT(*)::numeric(20,4)
          FROM public.tbl_supplier
        UNION ALL
        SELECT 'TOTAL_ACTIVE_SUPPLIERS', COUNT(*)::numeric(20,4)
          FROM public.tbl_supplier
         WHERE is_active = true
    )
    UPDATE public.tbl_summary_metric_lookup lookup
       SET value = metric_values.metric_value
      FROM metric_values
     WHERE lookup.look_up_key = metric_values.look_up_key;

    GET DIAGNOSTICS v_updated = ROW_COUNT;
    RETURN v_updated;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.fn_refresh_summary_metric_lookup() IS
    'Refreshes tbl_summary_metric_lookup values from challan, customer and supplier tables.';

SELECT public.fn_refresh_summary_metric_lookup();
