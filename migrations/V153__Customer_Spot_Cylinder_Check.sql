-- =============================================================================
-- V153 — Customer Spot Cylinder Check Book and Validation-only Entry
-- =============================================================================
-- Adds the fourth physical challan book type used for random customer cylinder
-- verification during a trip. This flow records observation/validation only.
-- It must not populate customer cylinder holding/custody or move cylinders.
-- =============================================================================

ALTER TYPE public.book_type_enum
    ADD VALUE IF NOT EXISTS 'CUSTOMER_SPOT_CYLINDER_CHECK';

CREATE TABLE IF NOT EXISTS public.tbl_customer_spot_cylinder_check (
    pk_customer_spot_check_id BIGINT GENERATED ALWAYS AS IDENTITY,

    fk_vehicle_trip BIGINT NOT NULL,
    fk_vehicle_load BIGINT NOT NULL,
    fk_vehicle_trip_stop BIGINT NULL,

    fk_customer BIGINT NOT NULL,
    fk_customer_address BIGINT NULL,

    fk_challan_book BIGINT NOT NULL,
    fk_page_audit_id BIGINT NOT NULL,
    sheet_number INTEGER NOT NULL,

    checked_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    checked_by VARCHAR(100) NULL,
    entry_status VARCHAR(30) NOT NULL DEFAULT 'DRAFT',
    system_validation_status VARCHAR(30) NOT NULL DEFAULT 'PENDING',

    full_count_observed INTEGER NOT NULL DEFAULT 0,
    empty_count_observed INTEGER NOT NULL DEFAULT 0,
    total_count_observed INTEGER NOT NULL DEFAULT 0,

    remarks VARCHAR(1000) NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT pk_customer_spot_cylinder_check PRIMARY KEY (pk_customer_spot_check_id),

    CONSTRAINT fk_customer_spot_check_trip
        FOREIGN KEY (fk_vehicle_trip)
        REFERENCES public.tbl_vehicle_trip(pk_vehicle_trip_id),

    CONSTRAINT fk_customer_spot_check_load
        FOREIGN KEY (fk_vehicle_load)
        REFERENCES public.tbl_vehicle_load(pk_vehicle_load_id),

    CONSTRAINT fk_customer_spot_check_stop
        FOREIGN KEY (fk_vehicle_trip_stop)
        REFERENCES public.tbl_vehicle_trip_stop(pk_stop_id),

    CONSTRAINT fk_customer_spot_check_customer
        FOREIGN KEY (fk_customer)
        REFERENCES public.tbl_customer(pk_customer_id),

    CONSTRAINT fk_customer_spot_check_address
        FOREIGN KEY (fk_customer_address)
        REFERENCES public.tbl_customer_address(pk_customer_address_id),

    CONSTRAINT fk_customer_spot_check_book
        FOREIGN KEY (fk_challan_book)
        REFERENCES public.tbl_challan_book_registry(pk_book_id),

    CONSTRAINT fk_customer_spot_check_page
        FOREIGN KEY (fk_page_audit_id)
        REFERENCES public.tbl_challan_page_audit_ledger(pk_page_audit_id),

    CONSTRAINT uq_customer_spot_check_page UNIQUE (fk_page_audit_id),

    CONSTRAINT chk_customer_spot_check_entry_status
        CHECK (entry_status IN ('DRAFT', 'SUBMITTED', 'CANCELLED')),

    CONSTRAINT chk_customer_spot_check_validation_status
        CHECK (system_validation_status IN (
            'PENDING',
            'MATCHED',
            'VARIANCE',
            'UNKNOWN_CYLINDER',
            'WRONG_CUSTOMER',
            'DUPLICATE_SERIAL',
            'INVALID_STATE'
        ))
);

CREATE TABLE IF NOT EXISTS public.tbl_customer_spot_cylinder_check_line (
    pk_customer_spot_check_line_id BIGINT GENERATED ALWAYS AS IDENTITY,

    fk_customer_spot_check BIGINT NOT NULL,
    observed_cylinder_serial VARCHAR(100) NOT NULL,
    fk_matched_cylinder BIGINT NULL,
    observed_condition VARCHAR(20) NOT NULL,

    expected_system_state VARCHAR(100) NULL,
    expected_customer_id BIGINT NULL,
    line_validation_status VARCHAR(30) NOT NULL DEFAULT 'PENDING',
    validation_message VARCHAR(1000) NULL,

    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT pk_customer_spot_cylinder_check_line PRIMARY KEY (pk_customer_spot_check_line_id),

    CONSTRAINT fk_customer_spot_check_line_header
        FOREIGN KEY (fk_customer_spot_check)
        REFERENCES public.tbl_customer_spot_cylinder_check(pk_customer_spot_check_id),

    CONSTRAINT fk_customer_spot_check_line_cylinder
        FOREIGN KEY (fk_matched_cylinder)
        REFERENCES public.tbl_cylinder(pk_cylinder_id),

    CONSTRAINT chk_customer_spot_check_line_condition
        CHECK (observed_condition IN ('FULL', 'EMPTY')),

    CONSTRAINT chk_customer_spot_check_line_validation_status
        CHECK (line_validation_status IN (
            'PENDING',
            'MATCHED',
            'NOT_HELD_BY_CUSTOMER',
            'UNKNOWN_CYLINDER',
            'STATE_MISMATCH',
            'DUPLICATE_IN_CHECK'
        )),

    CONSTRAINT uq_customer_spot_check_serial_once
        UNIQUE (fk_customer_spot_check, observed_cylinder_serial)
);

CREATE INDEX IF NOT EXISTS idx_customer_spot_check_trip
    ON public.tbl_customer_spot_cylinder_check(fk_vehicle_trip, fk_vehicle_load);

CREATE INDEX IF NOT EXISTS idx_customer_spot_check_customer
    ON public.tbl_customer_spot_cylinder_check(fk_customer, checked_at DESC);

CREATE INDEX IF NOT EXISTS idx_customer_spot_check_status
    ON public.tbl_customer_spot_cylinder_check(system_validation_status, entry_status);

CREATE INDEX IF NOT EXISTS idx_customer_spot_check_line_serial
    ON public.tbl_customer_spot_cylinder_check_line(UPPER(TRIM(observed_cylinder_serial)));

CREATE OR REPLACE VIEW public.vw_customer_spot_cylinder_check_summary AS
SELECT
    h.pk_customer_spot_check_id AS spot_check_id,
    h.fk_vehicle_trip,
    h.fk_vehicle_load,
    h.fk_customer,
    c.customer_name,
    h.fk_challan_book,
    b.book_code,
    CAST(b.book_type AS TEXT) AS book_type,
    h.sheet_number,
    h.checked_at,
    h.checked_by,
    h.entry_status,
    h.system_validation_status,
    h.full_count_observed,
    h.empty_count_observed,
    h.total_count_observed,
    COUNT(l.pk_customer_spot_check_line_id) AS line_count,
    SUM(CASE WHEN l.line_validation_status = 'MATCHED' THEN 1 ELSE 0 END) AS matched_line_count,
    SUM(CASE WHEN l.line_validation_status <> 'MATCHED' THEN 1 ELSE 0 END) AS variance_line_count
FROM public.tbl_customer_spot_cylinder_check h
JOIN public.tbl_customer c ON c.pk_customer_id = h.fk_customer
JOIN public.tbl_challan_book_registry b ON b.pk_book_id = h.fk_challan_book
LEFT JOIN public.tbl_customer_spot_cylinder_check_line l
       ON l.fk_customer_spot_check = h.pk_customer_spot_check_id
GROUP BY
    h.pk_customer_spot_check_id,
    h.fk_vehicle_trip,
    h.fk_vehicle_load,
    h.fk_customer,
    c.customer_name,
    h.fk_challan_book,
    b.book_code,
    CAST(b.book_type AS TEXT),
    h.sheet_number,
    h.checked_at,
    h.checked_by,
    h.entry_status,
    h.system_validation_status,
    h.full_count_observed,
    h.empty_count_observed,
    h.total_count_observed;

COMMENT ON TABLE public.tbl_customer_spot_cylinder_check IS
'Validation-only customer cylinder spot-check header. Does not create or update customer custody/holding.';

COMMENT ON TABLE public.tbl_customer_spot_cylinder_check_line IS
'Observed cylinder serials for customer spot-check; validation output only, no cylinder movement.';
