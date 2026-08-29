-- =============================================================================
-- V154 — Challan Page Photo Storage and Upload-aware Heatmap
-- =============================================================================
-- Adds database-backed storage for physical challan page photos/PDFs.
-- This is intentionally V154 because V153 already introduces the fourth challan
-- book type: CUSTOMER_SPOT_CYLINDER_CHECK.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.tbl_challan_page_photo (
    pk_challan_page_photo_id BIGINT GENERATED ALWAYS AS IDENTITY,
    fk_page_audit_id BIGINT NOT NULL,

    fk_vehicle_load BIGINT NULL,
    fk_vehicle_trip BIGINT NULL,
    fk_vehicle_trip_stop BIGINT NULL,

    original_file_name VARCHAR(255) NULL,
    content_type VARCHAR(100) NOT NULL,
    content_length BIGINT NOT NULL,
    photo_data BYTEA NOT NULL,

    uploaded_by_user_id BIGINT NULL,
    uploaded_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    active BOOLEAN NOT NULL DEFAULT TRUE,
    remarks VARCHAR(1000) NULL,

    CONSTRAINT pk_challan_page_photo PRIMARY KEY (pk_challan_page_photo_id),
    CONSTRAINT fk_challan_page_photo_page
        FOREIGN KEY (fk_page_audit_id)
        REFERENCES public.tbl_challan_page_audit_ledger(pk_page_audit_id),
    CONSTRAINT fk_challan_page_photo_vehicle_load
        FOREIGN KEY (fk_vehicle_load)
        REFERENCES public.tbl_vehicle_load(pk_vehicle_load_id),
    CONSTRAINT fk_challan_page_photo_vehicle_trip
        FOREIGN KEY (fk_vehicle_trip)
        REFERENCES public.tbl_vehicle_trip(pk_vehicle_trip_id),
    CONSTRAINT fk_challan_page_photo_vehicle_stop
        FOREIGN KEY (fk_vehicle_trip_stop)
        REFERENCES public.tbl_vehicle_trip_stop(pk_stop_id),
    CONSTRAINT chk_challan_page_photo_content_length
        CHECK (content_length > 0),
    CONSTRAINT chk_challan_page_photo_content_type
        CHECK (content_type IN ('image/jpeg', 'image/png', 'image/webp', 'application/pdf'))
);

CREATE INDEX IF NOT EXISTS idx_challan_page_photo_page_active
    ON public.tbl_challan_page_photo(fk_page_audit_id, active, uploaded_at DESC);

CREATE UNIQUE INDEX IF NOT EXISTS uq_challan_page_photo_one_active_per_page
    ON public.tbl_challan_page_photo(fk_page_audit_id)
    WHERE active = TRUE;

COMMENT ON TABLE public.tbl_challan_page_photo IS
'Physical challan page image/PDF stored in database and linked to tbl_challan_page_audit_ledger. One active uploaded image/PDF is maintained per physical challan leaf.';

-- Rebuild heatmap view so used leaves are split into uploaded and upload-pending.
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
    COUNT(CASE WHEN l.page_status = 'FLAGGED_MISSING'::public.page_status_enum THEN 1 END) AS missing_count,
    COUNT(CASE WHEN l.page_status = 'USED_CONFIRMED'::public.page_status_enum
                AND ph.pk_challan_page_photo_id IS NOT NULL THEN 1 END) AS uploaded_used_count,
    COUNT(CASE WHEN l.page_status = 'USED_CONFIRMED'::public.page_status_enum
                AND ph.pk_challan_page_photo_id IS NULL THEN 1 END) AS used_without_photo_count

FROM public.tbl_challan_book_registry b
JOIN public.tbl_challan_page_audit_ledger l
    ON b.pk_book_id = l.fk_book_id
LEFT JOIN public.tbl_challan_page_photo ph
    ON ph.fk_page_audit_id = l.pk_page_audit_id
   AND ph.active = TRUE
GROUP BY
    b.book_type,
    b.book_code,
    b.series_prefix,
    ((l.sheet_number - b.start_sheet_number) / 10)
ORDER BY
    b.book_type,
    b.book_code,
    ((l.sheet_number - b.start_sheet_number) / 10);

COMMENT ON VIEW public.vw_challan_heatmap_metrics IS
'Challan heatmap metrics with uploaded_used_count and used_without_photo_count for partially-filled upload-pending style. Includes all challan book types, including CUSTOMER_SPOT_CYLINDER_CHECK.';
