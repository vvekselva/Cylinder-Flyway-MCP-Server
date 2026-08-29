-- =============================================================================
-- V142__Summary_Metric_Decimal_Flag_And_Challan_Book_Card_Groups.sql
-- =============================================================================
-- PURPOSE
--   Add a display flag to tbl_summary_metric_lookup so the UI knows whether a
--   metric value should be rendered as a decimal value or as a whole number.
--
-- NOTE
--   Existing count metrics are whole-number values, so is_decimal_value = false.
--   Future metrics such as sales volume can set is_decimal_value = true.
-- =============================================================================

ALTER TABLE public.tbl_summary_metric_lookup
    ADD COLUMN IF NOT EXISTS is_decimal_value boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.tbl_summary_metric_lookup.is_decimal_value IS
    'If true, UI displays the metric with decimal places. If false, UI displays the metric as a whole number.';

-- Current configured metrics are count/page-count metrics and should display
-- without decimal points.
UPDATE public.tbl_summary_metric_lookup
   SET is_decimal_value = false
 WHERE look_up_key IN (
    'TOTAL_CHALLAN_BOOKS',
    'TOTAL_ACTIVE_BOOKS',
    'TOTAL_CLOSED_BOOKS',
    'TOTAL_DELIVERY_CHALLAN_BOOKS',
    'TOTAL_EMPTY_PICKUP_BOOKS',
    'TOTAL_SUPPLIER_EMPTY_BOOKS',
    'TOTAL_ACTIVE_DELIVERY_CHALLAN_BOOKS',
    'TOTAL_ACTIVE_EMPTY_PICKUP_BOOKS',
    'TOTAL_ACTIVE_SUPPLIER_EMPTY_DROPOFF_BOOKS',
    'TOTAL_UNUSED_PAGES_ACTIVE_DELIVERY_CHALLAN_BOOKS',
    'TOTAL_UNUSED_PAGES_ACTIVE_EMPTY_PICKUP_BOOKS',
    'TOTAL_UNUSED_PAGES_ACTIVE_SUPPLIER_EMPTY_DROPOFF_BOOKS',
    'TOTAL_CUSTOMERS',
    'TOTAL_ACTIVE_CUSTOMERS',
    'TOTAL_CUSTOMERS_WITH_GST_NUMBER',
    'TOTAL_CUSTOMERS_WITHOUT_GST_NUMBER',
    'TOTAL_ACTIVE_CUSTOMERS_WITH_GST_NUMBER',
    'TOTAL_ACTIVE_CUSTOMERS_WITHOUT_GST_NUMBER',
    'TOTAL_SUPPLIERS',
    'TOTAL_ACTIVE_SUPPLIERS'
 );

-- Replace seed function so future seed/update operations also maintain the
-- display-format flag.
CREATE OR REPLACE FUNCTION public.fn_seed_summary_metric_lookup()
RETURNS void AS $$
BEGIN
    INSERT INTO public.tbl_summary_metric_lookup
        (look_up_key, ui_label_for_the_lookup_field, actual_meaning, value, is_decimal_value)
    VALUES
        ('TOTAL_CHALLAN_BOOKS', 'Total Challan Books', 'Total number of challan books registered in the system.', 0, false),
        ('TOTAL_ACTIVE_BOOKS', 'Active Books', 'Total number of challan books that are not exhausted or archived.', 0, false),
        ('TOTAL_CLOSED_BOOKS', 'Closed Books', 'Total number of challan books with current location EXHAUSTED_ARCHIVED.', 0, false),
        ('TOTAL_DELIVERY_CHALLAN_BOOKS', 'Delivery Challan Books', 'Total number of books of type DELIVERY_CHALLAN.', 0, false),
        ('TOTAL_EMPTY_PICKUP_BOOKS', 'Empty Pickup Books', 'Total number of books of type EMPTY_PICKUP_CHALLAN.', 0, false),
        ('TOTAL_SUPPLIER_EMPTY_BOOKS', 'Supplier Empty Drop-off Books', 'Total number of supplier empty drop-off books. This maps to book type FILLING_NOTE.', 0, false),
        ('TOTAL_ACTIVE_DELIVERY_CHALLAN_BOOKS', 'Active Delivery Challan Books', 'Total active books of type DELIVERY_CHALLAN.', 0, false),
        ('TOTAL_ACTIVE_EMPTY_PICKUP_BOOKS', 'Active Empty Pickup Books', 'Total active books of type EMPTY_PICKUP_CHALLAN.', 0, false),
        ('TOTAL_ACTIVE_SUPPLIER_EMPTY_DROPOFF_BOOKS', 'Active Supplier Empty Drop-off Books', 'Total active supplier empty drop-off books. This maps to book type FILLING_NOTE.', 0, false),
        ('TOTAL_UNUSED_PAGES_ACTIVE_DELIVERY_CHALLAN_BOOKS', 'Unused Pages in Active Delivery Books', 'Total UNUSED pages in active DELIVERY_CHALLAN books.', 0, false),
        ('TOTAL_UNUSED_PAGES_ACTIVE_EMPTY_PICKUP_BOOKS', 'Unused Pages in Active Empty Pickup Books', 'Total UNUSED pages in active EMPTY_PICKUP_CHALLAN books.', 0, false),
        ('TOTAL_UNUSED_PAGES_ACTIVE_SUPPLIER_EMPTY_DROPOFF_BOOKS', 'Unused Pages in Active Supplier Empty Drop-off Books', 'Total UNUSED pages in active FILLING_NOTE books.', 0, false),
        ('TOTAL_CUSTOMERS', 'Total Customers', 'Total number of customers in the system.', 0, false),
        ('TOTAL_ACTIVE_CUSTOMERS', 'Active Customers', 'Total number of active customers.', 0, false),
        ('TOTAL_CUSTOMERS_WITH_GST_NUMBER', 'Customers With GST Number', 'Total number of customers where GST number is present and not blank.', 0, false),
        ('TOTAL_CUSTOMERS_WITHOUT_GST_NUMBER', 'Customers Without GST Number', 'Total number of customers where GST number is absent or blank.', 0, false),
        ('TOTAL_ACTIVE_CUSTOMERS_WITH_GST_NUMBER', 'Active Customers With GST Number', 'Total active customers where GST number is present and not blank.', 0, false),
        ('TOTAL_ACTIVE_CUSTOMERS_WITHOUT_GST_NUMBER', 'Active Customers Without GST Number', 'Total active customers where GST number is absent or blank.', 0, false),
        ('TOTAL_SUPPLIERS', 'Total Suppliers', 'Total number of suppliers in the system.', 0, false),
        ('TOTAL_ACTIVE_SUPPLIERS', 'Active Suppliers', 'Total number of active suppliers.', 0, false)
    ON CONFLICT (look_up_key) DO UPDATE
       SET ui_label_for_the_lookup_field = EXCLUDED.ui_label_for_the_lookup_field,
           actual_meaning = EXCLUDED.actual_meaning,
           is_decimal_value = EXCLUDED.is_decimal_value;
END;
$$ LANGUAGE plpgsql;

SELECT public.fn_seed_summary_metric_lookup();
SELECT public.fn_refresh_summary_metric_lookup();
