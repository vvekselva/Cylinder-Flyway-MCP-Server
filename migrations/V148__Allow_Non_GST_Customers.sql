/*
 * V148__Allow_Non_GST_Customers_REVISED.sql
 *
 * Purpose:
 *   Allow legitimate non-GST / unregistered customers in public.tbl_customer.
 *
 * Business rule:
 *   1. GST-registered customer      -> gst_number is present and unique.
 *   2. Non-GST/unregistered customer -> gst_number is NULL.
 *
 * Important:
 *   - Customer-name normalization, duplicate detection, and lookalike detection belong
 *     to the migration/import process, not to the final public application schema.
 *   - The public schema should only support the final clean customer master after the
 *     migration process has already resolved duplicates/lookalikes.
 */

-- 1. Remove the old rule that made GST globally mandatory/unique for every customer.
ALTER TABLE public.tbl_customer
    DROP CONSTRAINT IF EXISTS tbl_customer_unique;

-- 2. GST is optional for legitimate non-GST customers.
ALTER TABLE public.tbl_customer
    ALTER COLUMN gst_number DROP NOT NULL;

-- 3. Empty/blank GST should not be stored.
--    Non-GST customers must store gst_number as NULL.
ALTER TABLE public.tbl_customer
    ADD CONSTRAINT chk_tbl_customer_gst_number_not_blank
    CHECK (gst_number IS NULL OR btrim(gst_number) <> '');

-- 4. GST remains unique only when present.
CREATE UNIQUE INDEX IF NOT EXISTS ux_tbl_customer_gst_number_present
    ON public.tbl_customer (upper(btrim(gst_number)))
 WHERE gst_number IS NOT NULL;

COMMENT ON COLUMN public.tbl_customer.gst_number IS
'GST number. Nullable for legitimate non-GST/unregistered customers. Blank GST is not allowed; use NULL for non-GST customers.';

COMMENT ON INDEX public.ux_tbl_customer_gst_number_present IS
'Unique GST number for GST-registered customers only. Non-GST customers have NULL gst_number and are accepted.';
