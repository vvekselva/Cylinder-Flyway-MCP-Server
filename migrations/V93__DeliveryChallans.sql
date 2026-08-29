-- =============================================================================
-- CUSTOM DOMAIN ENUM REGISTRATIONS
-- =============================================================================
CREATE TYPE public.book_type_enum AS ENUM (
    'DELIVERY_CHALLAN', 
    'EMPTY_PICKUP_CHALLAN', 
    'FILLING_NOTE'
);

CREATE TYPE public.book_location_enum AS ENUM (
    'IN_OFFICE', 
    'IN_VEHICLE_TRANSIT', 
    'EXHAUSTED_ARCHIVED'
);

CREATE TYPE public.page_status_enum AS ENUM (
    'UNUSED',
    'USED_CONFIRMED',
    'CANCELLED_SPOILED',
    'FLAGGED_MISSING'
);


-- =============================================================================
-- 1. TABLE: tbl_challan_book_registry
-- Purpose: Holds metadata defining the physical book booklets and prefix ranges.
-- =============================================================================
CREATE TABLE public.tbl_challan_book_registry (
    pk_book_id          int8 GENERATED ALWAYS AS IDENTITY,
    book_code           varchar(30)  NOT NULL, 
    book_type           public.book_type_enum NOT NULL,
    series_prefix       varchar(10)  NULL,     
    start_sheet_number  int4         NOT NULL, 
    end_sheet_number    int4         NOT NULL, 
    current_location    public.book_location_enum NOT NULL DEFAULT 'IN_OFFICE',
    fk_assigned_vehicle int8         NULL,     
    created_at          timestamp    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at          timestamp    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    
    CONSTRAINT pk_challan_book_id PRIMARY KEY (pk_book_id),
    CONSTRAINT uq_book_code UNIQUE (book_code),
    CONSTRAINT chk_sheet_range CHECK (end_sheet_number >= start_sheet_number)
);


-- =============================================================================
-- 2. TABLE: tbl_challan_page_audit_ledger
-- Purpose: Dense matrix index mapping every physical single leaf sheet.
-- =============================================================================
CREATE TABLE public.tbl_challan_page_audit_ledger (
    pk_page_audit_id    int8 GENERATED ALWAYS AS IDENTITY,
    fk_book_id          int8         NOT NULL,
    sheet_number        int4         NOT NULL, 
    page_status         public.page_status_enum NOT NULL DEFAULT 'UNUSED',
    logged_by_user_id   int8         NULL,
    status_changed_at   timestamp    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    remarks             text         NULL,     
    
    CONSTRAINT pk_page_audit_id PRIMARY KEY (pk_page_audit_id),
    CONSTRAINT uq_book_sheet_index UNIQUE (fk_book_id, sheet_number),
    CONSTRAINT fk_ledger_book_registry FOREIGN KEY (fk_book_id) 
        REFERENCES public.tbl_challan_book_registry(pk_book_id) ON DELETE CASCADE
);

CREATE INDEX idx_page_audit_lookup ON public.tbl_challan_page_audit_ledger(page_status, fk_book_id);


-- =============================================================================
-- 3. TABLE: tbl_challan_transaction_link
-- Purpose: Polymorphic associative link table mapping single page sheets to jobs.
-- =============================================================================
CREATE TABLE public.tbl_challan_transaction_link (
    pk_link_id                  int8 GENERATED ALWAYS AS IDENTITY,
    fk_page_audit_id            int8         NOT NULL,
    linked_business_job_type    varchar(30)  NOT NULL, -- E.g., 'DELIVERY_RUN', 'EMPTY_COLLECTION', 'SUPPLIER_REFILL'
    fk_linked_business_job_id   int8         NOT NULL, -- Maps to targeted Entity Primary Key
    linked_at                   timestamp    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    
    CONSTRAINT pk_challan_transaction_link PRIMARY KEY (pk_link_id),
    CONSTRAINT uq_link_per_page UNIQUE (fk_page_audit_id),
    CONSTRAINT fk_link_to_page_audit FOREIGN KEY (fk_page_audit_id) 
        REFERENCES public.tbl_challan_page_audit_ledger(pk_page_audit_id) ON DELETE CASCADE
);

-- Indexing for optimized polymorphic query lookups
CREATE INDEX idx_challan_link_polymorphic 
ON public.tbl_challan_transaction_link (linked_business_job_type, fk_linked_business_job_id);


-- =============================================================================
-- 4. AUTOMATION ENGINE: Stored Procedure & Generation Trigger
-- Purpose: Automatically spawns child sheet nodes instantly upon master entry.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.fn_initialize_challan_book_pages()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_current_sheet int4;
BEGIN
    v_current_sheet := NEW.start_sheet_number;
    
    -- Dense iterative execution loop to automatically construct the ledger sheets
    WHILE v_current_sheet <= NEW.end_sheet_number LOOP
        INSERT INTO public.tbl_challan_page_audit_ledger (
            fk_book_id,
            sheet_number,
            page_status
        ) VALUES (
            NEW.pk_book_id,
            v_current_sheet,
            'UNUSED'
        );
        v_current_sheet := v_current_sheet + 1;
    END LOOP;
    
    RETURN NEW;
END;
$function$;

-- Attach automated trigger interceptor hook
CREATE TRIGGER trg_after_insert_challan_book
AFTER INSERT ON public.tbl_challan_book_registry
FOR EACH ROW
EXECUTE FUNCTION public.fn_initialize_challan_book_pages();


-- =============================================================================
-- 5. ANALYTICAL SEGMENT BUCKET VIEW FOR THE VISUAL DASHBOARD HEAT MAPS
-- Purpose: Groups page tracking records into modular sets of 10 for UI rendering.
-- =============================================================================
CREATE OR REPLACE VIEW public.vw_challan_heatmap_metrics AS
SELECT 
    b.book_code,
    b.book_type,
    -- Group sheets into modular bins of 10 pages (e.g., 0-9, 10-19)
    ((l.sheet_number - b.start_sheet_number) / 10) * 10 
        || '-' || (((l.sheet_number - b.start_sheet_number) / 10) * 10 + 9) AS sheet_range_bucket,
    COUNT(CASE WHEN l.page_status = 'FLAGGED_MISSING' THEN 1 END) AS missing_pages_count,
    COUNT(CASE WHEN l.page_status = 'CANCELLED_SPOILED' THEN 1 END) AS spoiled_pages_count,
    COUNT(CASE WHEN l.page_status = 'USED_CONFIRMED' THEN 1 END) AS clean_used_count,
    COUNT(CASE WHEN l.page_status = 'UNUSED' THEN 1 END) AS remaining_unused_count
FROM public.tbl_challan_book_registry b
JOIN public.tbl_challan_page_audit_ledger l ON b.pk_book_id = l.fk_book_id
GROUP BY b.book_code, b.book_type, ((l.sheet_number - b.start_sheet_number) / 10)
ORDER BY b.book_code, ((l.sheet_number - b.start_sheet_number) / 10);