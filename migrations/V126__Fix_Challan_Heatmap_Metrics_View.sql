-- =============================================================================
-- V126 — Fix Challan Heatmap Metrics View column aliases for JPA entity mapping
--
-- Problem:
--   ChallanHeatmapMetricsViewDo maps public.vw_challan_heatmap_metrics with:
--     bucket_key, book_type, book_code, series_prefix, sheet_range_bucket,
--     used_count, unused_count, spoiled_count, missing_count
--
--   The original V93 view exposed different aliases:
--     clean_used_count, remaining_unused_count, spoiled_pages_count,
--     missing_pages_count
--   and did not expose bucket_key / series_prefix.
--
-- Fix:
--   Drop and recreate the view with column names matching the JPA entity.
--   DROP is used instead of CREATE OR REPLACE because PostgreSQL does not allow
--   CREATE OR REPLACE VIEW to rename existing view columns.
-- =============================================================================

DROP VIEW IF EXISTS public.vw_challan_heatmap_metrics;

CREATE VIEW public.vw_challan_heatmap_metrics AS
SELECT
    CONCAT(
        b.book_type::text,
        '-',
        b.book_code,
        '-',
        COALESCE(b.series_prefix, ''),
        '-',
        (((l.sheet_number - b.start_sheet_number) / 10) * 10)::text,
        '-',
        ((((l.sheet_number - b.start_sheet_number) / 10) * 10) + 9)::text
    ) AS bucket_key,

    b.book_type::text AS book_type,
    b.book_code,
    b.series_prefix,

    (((l.sheet_number - b.start_sheet_number) / 10) * 10)::text
        || '-'
        || ((((l.sheet_number - b.start_sheet_number) / 10) * 10) + 9)::text AS sheet_range_bucket,

    COUNT(CASE WHEN l.page_status = 'USED_CONFIRMED'::public.page_status_enum THEN 1 END) AS used_count,
    COUNT(CASE WHEN l.page_status = 'UNUSED'::public.page_status_enum THEN 1 END) AS unused_count,
    COUNT(CASE WHEN l.page_status = 'CANCELLED_SPOILED'::public.page_status_enum THEN 1 END) AS spoiled_count,
    COUNT(CASE WHEN l.page_status = 'FLAGGED_MISSING'::public.page_status_enum THEN 1 END) AS missing_count

FROM public.tbl_challan_book_registry b
JOIN public.tbl_challan_page_audit_ledger l
    ON b.pk_book_id = l.fk_book_id
GROUP BY
    b.book_type,
    b.book_code,
    b.series_prefix,
    ((l.sheet_number - b.start_sheet_number) / 10)
ORDER BY
    b.book_type,
    b.book_code,
    ((l.sheet_number - b.start_sheet_number) / 10);
