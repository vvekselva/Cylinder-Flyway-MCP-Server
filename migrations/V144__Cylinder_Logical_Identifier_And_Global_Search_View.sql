-- ============================================================================
-- V144__Cylinder_Logical_Identifier_And_Global_Search_View.sql
--
-- Purpose:
--   Introduces the logical-cylinder / actual-identifier separation.
--
-- Design decision:
--   * tbl_cylinder remains the stable logical cylinder / lifecycle unit.
--   * tbl_cylinder_identifier stores the current and historical actual physical
--     identifiers, such as company serial, supplier serial, customer serial,
--     RFID, barcode, or template ID.
--   * Transaction tables such as tbl_cylinder_party_custody, yard inventory,
--     logistics, order lines and pickup lines continue to store only fk_cylinder.
--   * Views resolve both logical cylinder and actual identifier.
--
-- Compatibility:
--   vw_cylinder_global_search keeps the existing column cylinder_serial as the
--   display/search identifier, while adding explicit logical/actual identifier
--   columns for new screens and services.
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. Asset ownership type lookup
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.tbl_asset_ownership_type (
    pk_asset_ownership_type_id BIGSERIAL PRIMARY KEY,
    ownership_type_code        VARCHAR(50)  NOT NULL UNIQUE,
    ownership_type_name        VARCHAR(100) NOT NULL,
    is_company_fleet_asset     BOOLEAN      NOT NULL DEFAULT FALSE,
    is_external_asset          BOOLEAN      NOT NULL DEFAULT FALSE,
    is_exchangeable            BOOLEAN      NOT NULL DEFAULT FALSE,
    is_active                  BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at                 TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at                 TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO public.tbl_asset_ownership_type
(ownership_type_code, ownership_type_name, is_company_fleet_asset, is_external_asset, is_exchangeable)
VALUES
('COMPANY_OWNED',  'Company Owned',  TRUE,  FALSE, FALSE),
('SUPPLIER_OWNED', 'Supplier Owned', FALSE, TRUE,  TRUE),
('CUSTOMER_OWNED', 'Customer Owned', FALSE, TRUE,  TRUE)
ON CONFLICT (ownership_type_code) DO NOTHING;

-- ============================================================================
-- 2. Extend tbl_cylinder with ownership metadata.
--    Existing rows are backfilled as COMPANY_OWNED.
-- ============================================================================

ALTER TABLE public.tbl_cylinder
    ADD COLUMN IF NOT EXISTS fk_asset_ownership_type BIGINT NULL,
    ADD COLUMN IF NOT EXISTS fk_owner_supplier BIGINT NULL,
    ADD COLUMN IF NOT EXISTS fk_owner_customer BIGINT NULL,
    ADD COLUMN IF NOT EXISTS is_company_fleet_asset BOOLEAN NOT NULL DEFAULT TRUE,
    ADD COLUMN IF NOT EXISTS is_external_exchangeable BOOLEAN NOT NULL DEFAULT FALSE;

UPDATE public.tbl_cylinder c
SET fk_asset_ownership_type = aot.pk_asset_ownership_type_id,
    is_company_fleet_asset  = TRUE,
    is_external_exchangeable = FALSE
FROM public.tbl_asset_ownership_type aot
WHERE aot.ownership_type_code = 'COMPANY_OWNED'
  AND c.fk_asset_ownership_type IS NULL;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'fk_cylinder_asset_ownership_type'
    ) THEN
        ALTER TABLE public.tbl_cylinder
        ADD CONSTRAINT fk_cylinder_asset_ownership_type
        FOREIGN KEY (fk_asset_ownership_type)
        REFERENCES public.tbl_asset_ownership_type(pk_asset_ownership_type_id);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'fk_cylinder_owner_supplier'
    ) THEN
        ALTER TABLE public.tbl_cylinder
        ADD CONSTRAINT fk_cylinder_owner_supplier
        FOREIGN KEY (fk_owner_supplier)
        REFERENCES public.tbl_supplier(pk_supplier_id);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'fk_cylinder_owner_customer'
    ) THEN
        ALTER TABLE public.tbl_cylinder
        ADD CONSTRAINT fk_cylinder_owner_customer
        FOREIGN KEY (fk_owner_customer)
        REFERENCES public.tbl_customer(pk_customer_id);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'chk_cylinder_owner_party_consistency'
    ) THEN
        ALTER TABLE public.tbl_cylinder
        ADD CONSTRAINT chk_cylinder_owner_party_consistency
        CHECK (
            (
                is_company_fleet_asset = TRUE
                AND fk_owner_supplier IS NULL
                AND fk_owner_customer IS NULL
            )
            OR
            (
                is_company_fleet_asset = FALSE
                AND (
                    fk_owner_supplier IS NOT NULL
                    OR fk_owner_customer IS NOT NULL
                )
            )
        );
    END IF;
END $$;

ALTER TABLE public.tbl_cylinder
    ALTER COLUMN fk_asset_ownership_type SET NOT NULL;

CREATE INDEX IF NOT EXISTS idx_tbl_cylinder_ownership_type
ON public.tbl_cylinder(fk_asset_ownership_type);

CREATE INDEX IF NOT EXISTS idx_tbl_cylinder_owner_supplier
ON public.tbl_cylinder(fk_owner_supplier)
WHERE fk_owner_supplier IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_tbl_cylinder_owner_customer
ON public.tbl_cylinder(fk_owner_customer)
WHERE fk_owner_customer IS NOT NULL;

-- ============================================================================
-- 3. Actual cylinder identifier table.
--    This stores company serial, supplier serial, customer serial, RFID, barcode,
--    template identifiers, etc.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.tbl_cylinder_identifier (
    pk_cylinder_identifier_id BIGSERIAL PRIMARY KEY,

    fk_cylinder       BIGINT       NOT NULL,
    identifier_type   VARCHAR(50)  NOT NULL,
    identifier_value  VARCHAR(100) NOT NULL,

    is_primary        BOOLEAN      NOT NULL DEFAULT TRUE,
    is_active         BOOLEAN      NOT NULL DEFAULT TRUE,

    valid_from        TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    valid_to          TIMESTAMP    NULL,

    source_event_type VARCHAR(80)  NULL,
    source_event_id   BIGINT       NULL,

    remarks           VARCHAR(500) NULL,

    created_at        TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at        TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT fk_cylinder_identifier_cylinder
        FOREIGN KEY (fk_cylinder)
        REFERENCES public.tbl_cylinder(pk_cylinder_id),

    CONSTRAINT chk_cylinder_identifier_type
        CHECK (
            identifier_type IN (
                'COMPANY_SERIAL',
                'SUPPLIER_SERIAL',
                'CUSTOMER_SERIAL',
                'RFID',
                'BARCODE',
                'TEMPLATE_ID',
                'UNKNOWN_MARKING'
            )
        ),

    CONSTRAINT chk_cylinder_identifier_valid_window
        CHECK (valid_to IS NULL OR valid_to >= valid_from)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_cylinder_active_primary_identifier
ON public.tbl_cylinder_identifier(fk_cylinder)
WHERE is_active = TRUE
  AND is_primary = TRUE;

CREATE INDEX IF NOT EXISTS idx_cylinder_identifier_fk_cylinder
ON public.tbl_cylinder_identifier(fk_cylinder);

CREATE INDEX IF NOT EXISTS idx_cylinder_identifier_lower_value
ON public.tbl_cylinder_identifier(LOWER(identifier_value));

CREATE INDEX IF NOT EXISTS idx_cylinder_identifier_active_value
ON public.tbl_cylinder_identifier(LOWER(identifier_value))
WHERE is_active = TRUE;

-- Backfill all existing cylinders with their current tbl_cylinder.cylinder_serial
-- as the active company serial. This keeps existing UI/search behavior intact.
INSERT INTO public.tbl_cylinder_identifier
(
    fk_cylinder,
    identifier_type,
    identifier_value,
    is_primary,
    is_active,
    valid_from,
    source_event_type,
    remarks
)
SELECT
    c.pk_cylinder_id,
    'COMPANY_SERIAL',
    c.cylinder_serial,
    TRUE,
    TRUE,
    CURRENT_TIMESTAMP,
    'BACKFILL_FROM_TBL_CYLINDER',
    'Initial identifier backfill from tbl_cylinder.cylinder_serial'
FROM public.tbl_cylinder c
WHERE NOT EXISTS (
    SELECT 1
    FROM public.tbl_cylinder_identifier ci
    WHERE ci.fk_cylinder = c.pk_cylinder_id
      AND ci.is_primary = TRUE
      AND ci.is_active = TRUE
);

-- ============================================================================
-- 4. Identifier replacement event table.
--    No self-FK is added on tbl_cylinder. Replacements are tracked between
--    identifier rows for the same logical fk_cylinder.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.tbl_cylinder_identifier_replacement_event (
    pk_identifier_replacement_event_id BIGSERIAL PRIMARY KEY,

    fk_cylinder        BIGINT NOT NULL,
    fk_old_identifier  BIGINT NULL,
    fk_new_identifier  BIGINT NOT NULL,

    replacement_party_type VARCHAR(20) NULL,
    fk_supplier            BIGINT NULL,
    fk_customer            BIGINT NULL,

    replacement_reason VARCHAR(80) NOT NULL,

    source_event_type VARCHAR(80) NULL,
    source_event_id   BIGINT NULL,

    replaced_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    remarks     VARCHAR(500) NULL,

    CONSTRAINT fk_identifier_replacement_cylinder
        FOREIGN KEY (fk_cylinder)
        REFERENCES public.tbl_cylinder(pk_cylinder_id),

    CONSTRAINT fk_identifier_replacement_old_identifier
        FOREIGN KEY (fk_old_identifier)
        REFERENCES public.tbl_cylinder_identifier(pk_cylinder_identifier_id),

    CONSTRAINT fk_identifier_replacement_new_identifier
        FOREIGN KEY (fk_new_identifier)
        REFERENCES public.tbl_cylinder_identifier(pk_cylinder_identifier_id),

    CONSTRAINT fk_identifier_replacement_supplier
        FOREIGN KEY (fk_supplier)
        REFERENCES public.tbl_supplier(pk_supplier_id),

    CONSTRAINT fk_identifier_replacement_customer
        FOREIGN KEY (fk_customer)
        REFERENCES public.tbl_customer(pk_customer_id),

    CONSTRAINT chk_identifier_replacement_party_type
        CHECK (
            replacement_party_type IS NULL
            OR replacement_party_type IN ('SUPPLIER', 'CUSTOMER')
        ),

    CONSTRAINT chk_identifier_replacement_party_consistency
        CHECK (
            replacement_party_type IS NULL
            OR (
                replacement_party_type = 'SUPPLIER'
                AND fk_supplier IS NOT NULL
                AND fk_customer IS NULL
            )
            OR (
                replacement_party_type = 'CUSTOMER'
                AND fk_customer IS NOT NULL
                AND fk_supplier IS NULL
            )
        ),

    CONSTRAINT chk_identifier_replacement_reason
        CHECK (
            replacement_reason IN (
                'SUPPLIER_REPLACED_AFTER_REFILL',
                'CUSTOMER_REPLACED_IDENTIFIER',
                'RFID_RETAGGED',
                'BARCODE_REPLACED',
                'MANUAL_CORRECTION',
                'UNKNOWN_MARKING_CORRECTED'
            )
        )
);

CREATE INDEX IF NOT EXISTS idx_identifier_replacement_cylinder
ON public.tbl_cylinder_identifier_replacement_event(fk_cylinder);

CREATE INDEX IF NOT EXISTS idx_identifier_replacement_old_identifier
ON public.tbl_cylinder_identifier_replacement_event(fk_old_identifier);

CREATE INDEX IF NOT EXISTS idx_identifier_replacement_new_identifier
ON public.tbl_cylinder_identifier_replacement_event(fk_new_identifier);

-- ============================================================================
-- 5. Helper function to replace the active primary identifier safely.
--    This function keeps transaction tables unchanged because they continue
--    storing only fk_cylinder.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.fn_replace_cylinder_primary_identifier(
    p_fk_cylinder BIGINT,
    p_new_identifier_type VARCHAR,
    p_new_identifier_value VARCHAR,
    p_replacement_reason VARCHAR,
    p_replacement_party_type VARCHAR DEFAULT NULL,
    p_fk_supplier BIGINT DEFAULT NULL,
    p_fk_customer BIGINT DEFAULT NULL,
    p_source_event_type VARCHAR DEFAULT NULL,
    p_source_event_id BIGINT DEFAULT NULL,
    p_remarks VARCHAR DEFAULT NULL
)
RETURNS BIGINT AS $$
DECLARE
    v_old_identifier_id BIGINT;
    v_new_identifier_id BIGINT;
BEGIN
    SELECT pk_cylinder_identifier_id
      INTO v_old_identifier_id
      FROM public.tbl_cylinder_identifier
     WHERE fk_cylinder = p_fk_cylinder
       AND is_primary = TRUE
       AND is_active = TRUE
     ORDER BY valid_from DESC, pk_cylinder_identifier_id DESC
     LIMIT 1;

    IF v_old_identifier_id IS NOT NULL THEN
        UPDATE public.tbl_cylinder_identifier
           SET is_active = FALSE,
               valid_to = CURRENT_TIMESTAMP,
               updated_at = CURRENT_TIMESTAMP
         WHERE pk_cylinder_identifier_id = v_old_identifier_id;
    END IF;

    INSERT INTO public.tbl_cylinder_identifier
    (
        fk_cylinder,
        identifier_type,
        identifier_value,
        is_primary,
        is_active,
        valid_from,
        source_event_type,
        source_event_id,
        remarks
    )
    VALUES
    (
        p_fk_cylinder,
        p_new_identifier_type,
        p_new_identifier_value,
        TRUE,
        TRUE,
        CURRENT_TIMESTAMP,
        p_source_event_type,
        p_source_event_id,
        p_remarks
    )
    RETURNING pk_cylinder_identifier_id INTO v_new_identifier_id;

    INSERT INTO public.tbl_cylinder_identifier_replacement_event
    (
        fk_cylinder,
        fk_old_identifier,
        fk_new_identifier,
        replacement_party_type,
        fk_supplier,
        fk_customer,
        replacement_reason,
        source_event_type,
        source_event_id,
        remarks
    )
    VALUES
    (
        p_fk_cylinder,
        v_old_identifier_id,
        v_new_identifier_id,
        p_replacement_party_type,
        p_fk_supplier,
        p_fk_customer,
        p_replacement_reason,
        p_source_event_type,
        p_source_event_id,
        p_remarks
    );

    RETURN v_new_identifier_id;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- 6. Active identifier view.
--    Use this view from all current-state screens/searches.
-- ============================================================================

CREATE OR REPLACE VIEW public.vw_active_cylinder_identifier AS
SELECT
    c.pk_cylinder_id AS logical_cylinder_id,
    c.cylinder_serial AS logical_cylinder_code,

    ci.pk_cylinder_identifier_id AS actual_identifier_id,
    ci.identifier_type AS actual_identifier_type,
    ci.identifier_value AS actual_cylinder_identifier,

    COALESCE(ci.identifier_value, c.cylinder_serial) AS display_cylinder_identifier,

    c.description,
    c.total_quantity,
    c.fk_uom,
    c.fk_product,
    c.cylinder_type,

    aot.pk_asset_ownership_type_id AS asset_ownership_type_id,
    aot.ownership_type_code AS asset_ownership_type_code,
    aot.ownership_type_name AS asset_ownership_type_name,

    c.is_company_fleet_asset,
    c.is_external_exchangeable,

    c.fk_owner_supplier AS owner_supplier_id,
    supp.supplier_name AS owner_supplier_name,

    c.fk_owner_customer AS owner_customer_id,
    cust.customer_name AS owner_customer_name

FROM public.tbl_cylinder c
JOIN public.tbl_asset_ownership_type aot
    ON aot.pk_asset_ownership_type_id = c.fk_asset_ownership_type
LEFT JOIN public.tbl_supplier supp
    ON supp.pk_supplier_id = c.fk_owner_supplier
LEFT JOIN public.tbl_customer cust
    ON cust.pk_customer_id = c.fk_owner_customer
LEFT JOIN LATERAL (
    SELECT
        i.pk_cylinder_identifier_id,
        i.identifier_type,
        i.identifier_value
    FROM public.tbl_cylinder_identifier i
    WHERE i.fk_cylinder = c.pk_cylinder_id
      AND i.is_active = TRUE
      AND i.is_primary = TRUE
    ORDER BY i.valid_from DESC, i.pk_cylinder_identifier_id DESC
    LIMIT 1
) ci ON TRUE;

COMMENT ON VIEW public.vw_active_cylinder_identifier IS
'Resolves the stable logical cylinder from tbl_cylinder with the current active physical identifier from tbl_cylinder_identifier. Transaction tables keep only fk_cylinder; views resolve logical and actual identifiers.';

-- ============================================================================
-- 7. Replace global search view to expose both logical and actual identifiers.
--    Existing column cylinder_serial is preserved as display/search identifier.
-- ============================================================================

DROP VIEW IF EXISTS public.vw_cylinder_global_search;

CREATE OR REPLACE VIEW public.vw_cylinder_global_search AS
WITH ownership_rows AS (

    -- 1. Active Yard ownership
    SELECT
        c.pk_cylinder_id AS cylinder_id,
        aci.logical_cylinder_code,
        aci.actual_identifier_id,
        aci.actual_identifier_type,
        aci.actual_cylinder_identifier,
        aci.display_cylinder_identifier,
        aci.asset_ownership_type_id,
        aci.asset_ownership_type_code,
        aci.asset_ownership_type_name,
        aci.is_company_fleet_asset,
        aci.is_external_exchangeable,
        aci.owner_supplier_id,
        aci.owner_supplier_name,
        aci.owner_customer_id,
        aci.owner_customer_name,

        c.description,
        c.total_quantity,
        p.pk_product_id AS product_id,
        p.product_name,

        cs.pk_cylinder_state_id AS cylinder_state_id,
        cs.cylinder_state,

        'YARD'::varchar AS ownership_location,
        yil.pk_yard_inventory_line_id AS ownership_record_id,

        NULL::bigint AS customer_id,
        NULL::varchar AS customer_name,

        NULL::bigint AS supplier_id,
        NULL::varchar AS supplier_name,

        NULL::bigint AS vehicle_trip_id,
        NULL::bigint AS vehicle_load_id,

        yi.pk_yard_inventory_id AS yard_id,
        yi.yard_code,
        yi.yard_name,

        yil.entry_date AS entered_at

    FROM public.tbl_yard_inventory_line yil
    JOIN public.tbl_yard_inventory yi
        ON yi.pk_yard_inventory_id = yil.fk_yard_inventory
    JOIN public.tbl_cylinder c
        ON c.pk_cylinder_id = yil.fk_cylinder
    LEFT JOIN public.vw_active_cylinder_identifier aci
        ON aci.logical_cylinder_id = c.pk_cylinder_id
    LEFT JOIN public.tbl_product p
        ON p.pk_product_id = c.fk_product
    JOIN public.tbl_cylinder_states cs
        ON cs.pk_cylinder_state_id = yil.fk_cylinder_state
    WHERE yil.is_active = TRUE

    UNION ALL

    -- 2. Active Logistics / Vehicle ownership
    SELECT
        c.pk_cylinder_id AS cylinder_id,
        aci.logical_cylinder_code,
        aci.actual_identifier_id,
        aci.actual_identifier_type,
        aci.actual_cylinder_identifier,
        aci.display_cylinder_identifier,
        aci.asset_ownership_type_id,
        aci.asset_ownership_type_code,
        aci.asset_ownership_type_name,
        aci.is_company_fleet_asset,
        aci.is_external_exchangeable,
        aci.owner_supplier_id,
        aci.owner_supplier_name,
        aci.owner_customer_id,
        aci.owner_customer_name,

        c.description,
        c.total_quantity,
        p.pk_product_id AS product_id,
        p.product_name,

        cs.pk_cylinder_state_id AS cylinder_state_id,
        cs.cylinder_state,

        'LOGISTICS'::varchar AS ownership_location,
        clel.pk_cylinder_logistics_execution_line_id AS ownership_record_id,

        NULL::bigint AS customer_id,
        NULL::varchar AS customer_name,

        NULL::bigint AS supplier_id,
        NULL::varchar AS supplier_name,

        cle.fk_vehicle_trip AS vehicle_trip_id,
        cle.fk_vehicle_load AS vehicle_load_id,

        NULL::bigint AS yard_id,
        NULL::varchar AS yard_code,
        NULL::varchar AS yard_name,

        clel.created_at AS entered_at

    FROM public.tbl_cylinder_logistics_execution_line clel
    JOIN public.tbl_cylinder_logistics_execution cle
        ON cle.pk_cylinder_logistics_execution_id = clel.fk_cylinder_logistics_execution
    JOIN public.tbl_cylinder c
        ON c.pk_cylinder_id = clel.fk_cylinder
    LEFT JOIN public.vw_active_cylinder_identifier aci
        ON aci.logical_cylinder_id = c.pk_cylinder_id
    LEFT JOIN public.tbl_product p
        ON p.pk_product_id = c.fk_product
    JOIN public.tbl_cylinder_states cs
        ON cs.pk_cylinder_state_id = clel.fk_cylinder_state
    WHERE clel.is_active = TRUE
      AND cle.execution_status = 'OPEN'

    UNION ALL

    -- 3. Active Customer custody
    SELECT
        c.pk_cylinder_id AS cylinder_id,
        aci.logical_cylinder_code,
        aci.actual_identifier_id,
        aci.actual_identifier_type,
        aci.actual_cylinder_identifier,
        aci.display_cylinder_identifier,
        aci.asset_ownership_type_id,
        aci.asset_ownership_type_code,
        aci.asset_ownership_type_name,
        aci.is_company_fleet_asset,
        aci.is_external_exchangeable,
        aci.owner_supplier_id,
        aci.owner_supplier_name,
        aci.owner_customer_id,
        aci.owner_customer_name,

        c.description,
        c.total_quantity,
        p.pk_product_id AS product_id,
        p.product_name,

        cs.pk_cylinder_state_id AS cylinder_state_id,
        cs.cylinder_state,

        'CUSTOMER'::varchar AS ownership_location,
        cpc.pk_custody_id AS ownership_record_id,

        cust.pk_customer_id AS customer_id,
        cust.customer_name,

        NULL::bigint AS supplier_id,
        NULL::varchar AS supplier_name,

        cpc.fk_entry_trip AS vehicle_trip_id,
        cpc.fk_entry_load AS vehicle_load_id,

        NULL::bigint AS yard_id,
        NULL::varchar AS yard_code,
        NULL::varchar AS yard_name,

        cpc.entered_at AS entered_at

    FROM public.tbl_cylinder_party_custody cpc
    JOIN public.tbl_cylinder c
        ON c.pk_cylinder_id = cpc.fk_cylinder
    LEFT JOIN public.vw_active_cylinder_identifier aci
        ON aci.logical_cylinder_id = c.pk_cylinder_id
    LEFT JOIN public.tbl_product p
        ON p.pk_product_id = c.fk_product
    LEFT JOIN public.tbl_customer cust
        ON cust.pk_customer_id = cpc.fk_customer
    JOIN public.tbl_cylinder_states cs
        ON cs.cylinder_state = 'DELIVERED_FOR_CONSUMPTION'
    WHERE cpc.custody_status = 'ACTIVE'
      AND cpc.party_type = 'CUSTOMER'

    UNION ALL

    -- 4. Active Supplier custody
    SELECT
        c.pk_cylinder_id AS cylinder_id,
        aci.logical_cylinder_code,
        aci.actual_identifier_id,
        aci.actual_identifier_type,
        aci.actual_cylinder_identifier,
        aci.display_cylinder_identifier,
        aci.asset_ownership_type_id,
        aci.asset_ownership_type_code,
        aci.asset_ownership_type_name,
        aci.is_company_fleet_asset,
        aci.is_external_exchangeable,
        aci.owner_supplier_id,
        aci.owner_supplier_name,
        aci.owner_customer_id,
        aci.owner_customer_name,

        c.description,
        c.total_quantity,
        p.pk_product_id AS product_id,
        p.product_name,

        cs.pk_cylinder_state_id AS cylinder_state_id,
        cs.cylinder_state,

        'SUPPLIER'::varchar AS ownership_location,
        cpc.pk_custody_id AS ownership_record_id,

        NULL::bigint AS customer_id,
        NULL::varchar AS customer_name,

        supp.pk_supplier_id AS supplier_id,
        supp.supplier_name,

        cpc.fk_entry_trip AS vehicle_trip_id,
        cpc.fk_entry_load AS vehicle_load_id,

        NULL::bigint AS yard_id,
        NULL::varchar AS yard_code,
        NULL::varchar AS yard_name,

        cpc.entered_at AS entered_at

    FROM public.tbl_cylinder_party_custody cpc
    JOIN public.tbl_cylinder c
        ON c.pk_cylinder_id = cpc.fk_cylinder
    LEFT JOIN public.vw_active_cylinder_identifier aci
        ON aci.logical_cylinder_id = c.pk_cylinder_id
    LEFT JOIN public.tbl_product p
        ON p.pk_product_id = c.fk_product
    LEFT JOIN public.tbl_supplier supp
        ON supp.pk_supplier_id = cpc.fk_supplier
    JOIN public.tbl_cylinder_states cs
        ON cs.cylinder_state = 'EMPTY_DELIVERED_FOR_REFILL'
    WHERE cpc.custody_status = 'ACTIVE'
      AND cpc.party_type = 'SUPPLIER'
),
ownership_count AS (
    SELECT
        cylinder_id,
        COUNT(*) AS active_ownership_count
    FROM ownership_rows
    GROUP BY cylinder_id
),
normal_or_unknown_rows AS (
    SELECT
        COALESCE(
            o.ownership_location || '-' || o.ownership_record_id::text,
            'UNKNOWN-' || c.pk_cylinder_id::text
        ) AS search_key,

        c.pk_cylinder_id AS cylinder_id,

        -- Backward-compatible column. Existing search can continue to use this.
        COALESCE(aci.display_cylinder_identifier, c.cylinder_serial) AS cylinder_serial,

        aci.logical_cylinder_code,
        aci.actual_identifier_id,
        aci.actual_identifier_type,
        aci.actual_cylinder_identifier,
        COALESCE(aci.display_cylinder_identifier, c.cylinder_serial) AS display_cylinder_identifier,

        aci.asset_ownership_type_id,
        aci.asset_ownership_type_code,
        aci.asset_ownership_type_name,
        aci.is_company_fleet_asset,
        aci.is_external_exchangeable,
        aci.owner_supplier_id,
        aci.owner_supplier_name,
        aci.owner_customer_id,
        aci.owner_customer_name,

        c.description,
        c.total_quantity,

        COALESCE(o.product_id, p.pk_product_id) AS product_id,
        COALESCE(o.product_name, p.product_name) AS product_name,

        o.cylinder_state_id,

        CASE
            WHEN oc.active_ownership_count IS NULL THEN 'OWNERSHIP_UNKNOWN'
            ELSE o.cylinder_state
        END AS cylinder_state,

        CASE
            WHEN oc.active_ownership_count IS NULL THEN 'UNKNOWN'
            ELSE o.ownership_location
        END AS ownership_location,

        o.ownership_record_id,

        o.customer_id,
        o.customer_name,

        o.supplier_id,
        o.supplier_name,

        o.vehicle_trip_id,
        o.vehicle_load_id,

        o.yard_id,
        o.yard_code,
        o.yard_name,

        o.entered_at,

        COALESCE(oc.active_ownership_count, 0) AS active_ownership_count,

        CASE
            WHEN oc.active_ownership_count IS NULL THEN 'UNKNOWN'
            ELSE 'OK'
        END AS ownership_status

    FROM public.tbl_cylinder c
    LEFT JOIN public.vw_active_cylinder_identifier aci
        ON aci.logical_cylinder_id = c.pk_cylinder_id
    LEFT JOIN public.tbl_product p
        ON p.pk_product_id = c.fk_product
    LEFT JOIN ownership_count oc
        ON oc.cylinder_id = c.pk_cylinder_id
    LEFT JOIN ownership_rows o
        ON o.cylinder_id = c.pk_cylinder_id
    WHERE COALESCE(oc.active_ownership_count, 0) <= 1
),
conflict_rows AS (
    SELECT
        'CONFLICT-' || c.pk_cylinder_id::text AS search_key,

        c.pk_cylinder_id AS cylinder_id,

        COALESCE(aci.display_cylinder_identifier, c.cylinder_serial) AS cylinder_serial,

        aci.logical_cylinder_code,
        aci.actual_identifier_id,
        aci.actual_identifier_type,
        aci.actual_cylinder_identifier,
        COALESCE(aci.display_cylinder_identifier, c.cylinder_serial) AS display_cylinder_identifier,

        aci.asset_ownership_type_id,
        aci.asset_ownership_type_code,
        aci.asset_ownership_type_name,
        aci.is_company_fleet_asset,
        aci.is_external_exchangeable,
        aci.owner_supplier_id,
        aci.owner_supplier_name,
        aci.owner_customer_id,
        aci.owner_customer_name,

        c.description,
        c.total_quantity,

        p.pk_product_id AS product_id,
        p.product_name,

        NULL::bigint AS cylinder_state_id,
        'OWNERSHIP_CONFLICT'::varchar AS cylinder_state,
        'CONFLICT'::varchar AS ownership_location,

        NULL::bigint AS ownership_record_id,

        NULL::bigint AS customer_id,
        NULL::varchar AS customer_name,

        NULL::bigint AS supplier_id,
        NULL::varchar AS supplier_name,

        NULL::bigint AS vehicle_trip_id,
        NULL::bigint AS vehicle_load_id,

        NULL::bigint AS yard_id,
        NULL::varchar AS yard_code,
        NULL::varchar AS yard_name,

        NULL::timestamp AS entered_at,

        oc.active_ownership_count,

        'CONFLICT'::varchar AS ownership_status

    FROM public.tbl_cylinder c
    LEFT JOIN public.vw_active_cylinder_identifier aci
        ON aci.logical_cylinder_id = c.pk_cylinder_id
    LEFT JOIN public.tbl_product p
        ON p.pk_product_id = c.fk_product
    JOIN ownership_count oc
        ON oc.cylinder_id = c.pk_cylinder_id
    WHERE oc.active_ownership_count > 1
)

SELECT * FROM normal_or_unknown_rows
UNION ALL
SELECT * FROM conflict_rows;

CREATE INDEX IF NOT EXISTS idx_tbl_cylinder_lower_serial
ON public.tbl_cylinder (LOWER(cylinder_serial));

COMMENT ON VIEW public.vw_cylinder_global_search IS
'Global cylinder search read model. Transaction tables keep fk_cylinder only. This view exposes both logical cylinder code and actual active identifier. cylinder_serial is retained as a backward-compatible display/search identifier.';

-- ============================================================================
-- 8. Historical/as-of custody identifier view.
--    This does not change tbl_cylinder_party_custody. It resolves which
--    identifier was active at custody entry/exit time using valid_from/valid_to.
-- ============================================================================

CREATE OR REPLACE VIEW public.vw_cylinder_party_custody_with_identifiers AS
SELECT
    cpc.pk_custody_id,
    cpc.fk_cylinder AS logical_cylinder_id,
    c.cylinder_serial AS logical_cylinder_code,

    entry_ci.pk_cylinder_identifier_id AS entry_identifier_id,
    entry_ci.identifier_type AS entry_identifier_type,
    entry_ci.identifier_value AS entry_actual_cylinder_identifier,

    exit_ci.pk_cylinder_identifier_id AS exit_identifier_id,
    exit_ci.identifier_type AS exit_identifier_type,
    exit_ci.identifier_value AS exit_actual_cylinder_identifier,

    active_ci.actual_identifier_id AS active_identifier_id,
    active_ci.actual_identifier_type AS active_identifier_type,
    active_ci.actual_cylinder_identifier AS active_actual_cylinder_identifier,
    active_ci.display_cylinder_identifier,

    active_ci.asset_ownership_type_id,
    active_ci.asset_ownership_type_code,
    active_ci.asset_ownership_type_name,
    active_ci.is_company_fleet_asset,
    active_ci.is_external_exchangeable,
    active_ci.owner_supplier_id,
    active_ci.owner_supplier_name,
    active_ci.owner_customer_id,
    active_ci.owner_customer_name,

    cpc.party_type,
    cpc.fk_customer,
    cust.customer_name,
    cpc.fk_supplier,
    supp.supplier_name,
    cpc.fk_customer_address,

    cpc.entry_event_type,
    cpc.fk_entry_order,
    cpc.fk_entry_supplier_trip,
    cpc.fk_entry_trip,
    cpc.fk_entry_load,
    cpc.fk_entry_stop,
    cpc.entered_at,

    cpc.exit_event_type,
    cpc.fk_exit_empty_pickup,
    cpc.fk_exit_supplier_refill_collection,
    cpc.fk_exit_trip,
    cpc.fk_exit_load,
    cpc.fk_exit_stop,
    cpc.exited_at,

    cpc.custody_status,
    cpc.aging_due_at,
    cpc.escalated_at,
    cpc.remarks

FROM public.tbl_cylinder_party_custody cpc
JOIN public.tbl_cylinder c
    ON c.pk_cylinder_id = cpc.fk_cylinder
LEFT JOIN public.tbl_customer cust
    ON cust.pk_customer_id = cpc.fk_customer
LEFT JOIN public.tbl_supplier supp
    ON supp.pk_supplier_id = cpc.fk_supplier
LEFT JOIN public.vw_active_cylinder_identifier active_ci
    ON active_ci.logical_cylinder_id = cpc.fk_cylinder
LEFT JOIN LATERAL (
    SELECT
        ci.pk_cylinder_identifier_id,
        ci.identifier_type,
        ci.identifier_value
    FROM public.tbl_cylinder_identifier ci
    WHERE ci.fk_cylinder = cpc.fk_cylinder
      AND ci.is_primary = TRUE
      AND ci.valid_from <= cpc.entered_at
      AND (ci.valid_to IS NULL OR ci.valid_to > cpc.entered_at)
    ORDER BY ci.valid_from DESC, ci.pk_cylinder_identifier_id DESC
    LIMIT 1
) entry_ci ON TRUE
LEFT JOIN LATERAL (
    SELECT
        ci.pk_cylinder_identifier_id,
        ci.identifier_type,
        ci.identifier_value
    FROM public.tbl_cylinder_identifier ci
    WHERE ci.fk_cylinder = cpc.fk_cylinder
      AND ci.is_primary = TRUE
      AND cpc.exited_at IS NOT NULL
      AND ci.valid_from <= cpc.exited_at
      AND (ci.valid_to IS NULL OR ci.valid_to > cpc.exited_at)
    ORDER BY ci.valid_from DESC, ci.pk_cylinder_identifier_id DESC
    LIMIT 1
) exit_ci ON TRUE;

COMMENT ON VIEW public.vw_cylinder_party_custody_with_identifiers IS
'Party custody read model with logical cylinder and actual identifiers. Entry/exit identifiers are resolved as-of entered_at/exited_at; active identifier shows current mapping.';

COMMIT;
