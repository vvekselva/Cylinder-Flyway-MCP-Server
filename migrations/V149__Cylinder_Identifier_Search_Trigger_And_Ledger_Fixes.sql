-- ============================================================================
-- V149__Cylinder_Identifier_Search_Trigger_And_Ledger_Fixes.sql
--
-- Purpose:
--   Finalizes the logical-cylinder / actual-identifier model introduced by V144.
--
--   * tbl_cylinder_identifier is the single active actual-identifier authority
--     for COMPANY_OWNED, SUPPLIER_OWNED and CUSTOMER_OWNED cylinders.
--   * Lifecycle audit remains common for all asset types.
--   * COMMISSIONED and company fleet ledger movements apply only to company-owned
--     fleet assets.
--   * Supplier/customer-owned inserts and close events are recorded in an
--     external asset ledger, not the company fleet ledger.
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. Enforce actual identifier uniqueness for all asset types.
-- ============================================================================

CREATE UNIQUE INDEX IF NOT EXISTS uq_cylinder_identifier_active_primary_value
ON public.tbl_cylinder_identifier (LOWER(BTRIM(identifier_value)))
WHERE is_active = TRUE
  AND is_primary = TRUE;

-- ============================================================================
-- 2. Minimal external asset ledger for supplier/customer-owned asset accounting.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.tbl_external_cylinder_asset_ledger (
    pk_external_asset_ledger_id BIGSERIAL PRIMARY KEY,

    fk_cylinder                 BIGINT       NOT NULL,
    fk_asset_ownership_type     BIGINT       NOT NULL,

    fk_owner_supplier           BIGINT       NULL,
    fk_owner_customer           BIGINT       NULL,

    fk_product                  BIGINT       NOT NULL,
    cylinder_type               VARCHAR(20)  NULL,

    event_type                  VARCHAR(80)  NOT NULL,
    delta                       NUMERIC(10,2) NOT NULL DEFAULT 1,

    event_at                    TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    remarks                     VARCHAR(500) NULL,

    CONSTRAINT fk_external_asset_ledger_cylinder
        FOREIGN KEY (fk_cylinder)
        REFERENCES public.tbl_cylinder(pk_cylinder_id),

    CONSTRAINT fk_external_asset_ledger_ownership_type
        FOREIGN KEY (fk_asset_ownership_type)
        REFERENCES public.tbl_asset_ownership_type(pk_asset_ownership_type_id),

    CONSTRAINT chk_external_asset_ledger_event_type
        CHECK (
            event_type IN (
                'SUPPLIER_ASSET_REGISTERED',
                'CUSTOMER_ASSET_REGISTERED',
                'SUPPLIER_ASSET_IDENTIFIER_REPLACED',
                'CUSTOMER_ASSET_IDENTIFIER_REPLACED',
                'SUPPLIER_ASSET_CLOSED',
                'CUSTOMER_ASSET_CLOSED',
                'SUPPLIER_ASSET_LOST',
                'CUSTOMER_ASSET_LOST',
                'SUPPLIER_ASSET_DAMAGED',
                'CUSTOMER_ASSET_DAMAGED',
                'SUPPLIER_ASSET_DECOMMISSIONED',
                'CUSTOMER_ASSET_DECOMMISSIONED'
            )
        )
);

CREATE INDEX IF NOT EXISTS idx_external_asset_ledger_cylinder
ON public.tbl_external_cylinder_asset_ledger(fk_cylinder);

CREATE INDEX IF NOT EXISTS idx_external_asset_ledger_ownership
ON public.tbl_external_cylinder_asset_ledger(fk_asset_ownership_type, event_type, event_at);

-- ============================================================================
-- 3. Safe identifier replacement with duplicate protection.
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
    v_party_asset_account_id BIGINT := NULL;
    v_asset_ownership_type_code VARCHAR(50);
BEGIN
    IF p_fk_cylinder IS NULL THEN
        RAISE EXCEPTION 'p_fk_cylinder is required';
    END IF;

    IF BTRIM(COALESCE(p_new_identifier_value, '')) = '' THEN
        RAISE EXCEPTION 'New cylinder identifier is required';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.tbl_cylinder_identifier ci
        WHERE LOWER(BTRIM(ci.identifier_value)) = LOWER(BTRIM(p_new_identifier_value))
          AND ci.is_active = TRUE
          AND ci.is_primary = TRUE
          AND ci.fk_cylinder <> p_fk_cylinder
    ) THEN
        RAISE EXCEPTION
            'Cylinder identifier % is already active for another logical cylinder',
            p_new_identifier_value;
    END IF;

    SELECT ci.pk_cylinder_identifier_id
      INTO v_old_identifier_id
      FROM public.tbl_cylinder_identifier ci
     WHERE ci.fk_cylinder = p_fk_cylinder
       AND ci.is_primary = TRUE
       AND ci.is_active = TRUE
     ORDER BY ci.valid_from DESC, ci.pk_cylinder_identifier_id DESC
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
        BTRIM(p_new_identifier_value),
        TRUE,
        TRUE,
        CURRENT_TIMESTAMP,
        p_source_event_type,
        p_source_event_id,
        p_remarks
    )
    RETURNING pk_cylinder_identifier_id INTO v_new_identifier_id;

    SELECT aot.ownership_type_code
      INTO v_asset_ownership_type_code
      FROM public.tbl_cylinder c
      LEFT JOIN public.tbl_asset_ownership_type aot
             ON aot.pk_asset_ownership_type_id = c.fk_asset_ownership_type
     WHERE c.pk_cylinder_id = p_fk_cylinder;

    INSERT INTO public.tbl_cylinder_identifier_replacement_event
    (
        fk_cylinder,
        fk_old_identifier,
        fk_new_identifier,
        fk_party_asset_account,
        replacement_party_type,
        fk_supplier,
        fk_customer,
        replacement_reason,
        source_event_type,
        source_event_id,
        replaced_at,
        remarks
    )
    VALUES
    (
        p_fk_cylinder,
        v_old_identifier_id,
        v_new_identifier_id,
        v_party_asset_account_id,
        p_replacement_party_type,
        p_fk_supplier,
        p_fk_customer,
        p_replacement_reason,
        p_source_event_type,
        p_source_event_id,
        CURRENT_TIMESTAMP,
        p_remarks
    );

    IF v_asset_ownership_type_code IN ('SUPPLIER_OWNED', 'CUSTOMER_OWNED') THEN
        INSERT INTO public.tbl_external_cylinder_asset_ledger (
            fk_cylinder,
            fk_asset_ownership_type,
            fk_owner_supplier,
            fk_owner_customer,
            fk_product,
            cylinder_type,
            event_type,
            delta,
            remarks
        )
        SELECT c.pk_cylinder_id,
               c.fk_asset_ownership_type,
               c.fk_owner_supplier,
               c.fk_owner_customer,
               c.fk_product,
               NULL,
               CASE
                   WHEN v_asset_ownership_type_code = 'SUPPLIER_OWNED'
                       THEN 'SUPPLIER_ASSET_IDENTIFIER_REPLACED'
                   ELSE 'CUSTOMER_ASSET_IDENTIFIER_REPLACED'
               END,
               0,
               'Primary identifier replaced: ' || COALESCE(p_remarks, p_new_identifier_value)
          FROM public.tbl_cylinder c
         WHERE c.pk_cylinder_id = p_fk_cylinder;
    END IF;

    RETURN v_new_identifier_id;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- 4. Ownership-aware lifecycle audit on cylinder insert.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.fn_cylinder_state_lifecycle_logging()
RETURNS TRIGGER AS $$
DECLARE
    v_ownership_type_code VARCHAR(50);
    v_state_commissioned_id BIGINT;
    v_state_empty_id BIGINT;
    v_state_full_id BIGINT;
BEGIN
    SELECT aot.ownership_type_code
      INTO v_ownership_type_code
      FROM public.tbl_asset_ownership_type aot
     WHERE aot.pk_asset_ownership_type_id = NEW.fk_asset_ownership_type;

    IF v_ownership_type_code IS NULL THEN
        RAISE EXCEPTION 'Cylinder % has no valid asset ownership type', NEW.pk_cylinder_id;
    END IF;

    SELECT pk_cylinder_state_id INTO v_state_commissioned_id
      FROM public.tbl_cylinder_states WHERE cylinder_state = 'COMMISSIONED';

    SELECT pk_cylinder_state_id INTO v_state_empty_id
      FROM public.tbl_cylinder_states WHERE cylinder_state = 'EMPTY';

    SELECT pk_cylinder_state_id INTO v_state_full_id
      FROM public.tbl_cylinder_states WHERE cylinder_state = 'FULL';

    IF v_ownership_type_code = 'COMPANY_OWNED' THEN
        INSERT INTO public.tbl_cylinder_state_audit (
            pk_audit_id, fk_cylinder, fk_previous_state, fk_new_state, changed_at, remarks
        )
        VALUES (
            nextval('public.pk_cylinder_state_id_serial'),
            NEW.pk_cylinder_id,
            v_state_commissioned_id,
            v_state_commissioned_id,
            CURRENT_TIMESTAMP,
            'Initial commissioning of company-owned cylinder'
        );

        INSERT INTO public.tbl_cylinder_state_audit (
            pk_audit_id, fk_cylinder, fk_previous_state, fk_new_state, changed_at, remarks
        )
        VALUES (
            nextval('public.pk_cylinder_state_id_serial'),
            NEW.pk_cylinder_id,
            v_state_commissioned_id,
            v_state_empty_id,
            CURRENT_TIMESTAMP,
            'Company-owned cylinder activated to EMPTY at yard'
        );

    ELSIF v_ownership_type_code = 'SUPPLIER_OWNED' THEN
        INSERT INTO public.tbl_cylinder_state_audit (
            pk_audit_id, fk_cylinder, fk_previous_state, fk_new_state, changed_at, remarks
        )
        VALUES (
            nextval('public.pk_cylinder_state_id_serial'),
            NEW.pk_cylinder_id,
            v_state_full_id,
            v_state_full_id,
            CURRENT_TIMESTAMP,
            'Supplier-owned cylinder received as FULL; no commissioning event'
        );

    ELSIF v_ownership_type_code = 'CUSTOMER_OWNED' THEN
        INSERT INTO public.tbl_cylinder_state_audit (
            pk_audit_id, fk_cylinder, fk_previous_state, fk_new_state, changed_at, remarks
        )
        VALUES (
            nextval('public.pk_cylinder_state_id_serial'),
            NEW.pk_cylinder_id,
            v_state_empty_id,
            v_state_empty_id,
            CURRENT_TIMESTAMP,
            'Customer-owned cylinder received as EMPTY; no commissioning event'
        );

    ELSE
        RAISE EXCEPTION 'Unsupported asset ownership type % for cylinder %',
            v_ownership_type_code, NEW.pk_cylinder_id;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- 5. Company-fleet-only insert ledger; supplier/customer inserts go to external
--    asset ledger.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.fn_fleet_ledger_on_cylinder_insert()
RETURNS TRIGGER AS $$
DECLARE
    v_before int4;
    v_ownership_type_code VARCHAR(50);
BEGIN
    SELECT aot.ownership_type_code
      INTO v_ownership_type_code
      FROM public.tbl_asset_ownership_type aot
     WHERE aot.pk_asset_ownership_type_id = NEW.fk_asset_ownership_type;

    IF COALESCE(NEW.is_company_fleet_asset, FALSE) = TRUE THEN
        v_before := public.fn_current_fleet_count();

        INSERT INTO public.tbl_cylinder_fleet_ledger (
            fk_cylinder, event_type, fleet_count_before, fleet_count_after, delta, remarks
        ) VALUES (
            NEW.pk_cylinder_id,
            'COMMISSIONED',
            v_before,
            v_before + 1,
            1,
            'Company-owned cylinder commissioned: logical=' || NEW.cylinder_serial
        );

        RETURN NEW;
    END IF;

    IF v_ownership_type_code IN ('SUPPLIER_OWNED', 'CUSTOMER_OWNED') THEN
        INSERT INTO public.tbl_external_cylinder_asset_ledger (
            fk_cylinder,
            fk_asset_ownership_type,
            fk_owner_supplier,
            fk_owner_customer,
            fk_product,
            cylinder_type,
            event_type,
            delta,
            remarks
        ) VALUES (
            NEW.pk_cylinder_id,
            NEW.fk_asset_ownership_type,
            NEW.fk_owner_supplier,
            NEW.fk_owner_customer,
            NEW.fk_product,
            NULL,
            CASE
                WHEN v_ownership_type_code = 'SUPPLIER_OWNED' THEN 'SUPPLIER_ASSET_REGISTERED'
                ELSE 'CUSTOMER_ASSET_REGISTERED'
            END,
            1,
            'External logical cylinder registered: logical=' || NEW.cylinder_serial
        );
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- 6. Company-fleet-only shrink ledger; external terminal states go to external
--    asset ledger.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.fn_fleet_ledger_on_state_audit()
RETURNS TRIGGER AS $$
DECLARE
    v_new_state_name varchar(100);
    v_event_type     varchar(80);
    v_before         int4;
    v_is_company_fleet_asset BOOLEAN;
    v_ownership_type_code VARCHAR(50);
BEGIN
    SELECT cs.cylinder_state
      INTO v_new_state_name
      FROM public.tbl_cylinder_states cs
     WHERE cs.pk_cylinder_state_id = NEW.fk_new_state;

    SELECT COALESCE(c.is_company_fleet_asset, FALSE),
           aot.ownership_type_code
      INTO v_is_company_fleet_asset,
           v_ownership_type_code
      FROM public.tbl_cylinder c
      LEFT JOIN public.tbl_asset_ownership_type aot
             ON aot.pk_asset_ownership_type_id = c.fk_asset_ownership_type
     WHERE c.pk_cylinder_id = NEW.fk_cylinder;

    IF v_new_state_name = 'DECOMMISSIONED' OR v_new_state_name = 'DECOMISSIONED' THEN
        v_event_type := 'DECOMMISSIONED';
    ELSIF v_new_state_name = 'LOST' THEN
        v_event_type := 'LOST_CONFIRMED';
    ELSIF v_new_state_name = 'DAMAGED' THEN
        v_event_type := 'DAMAGED';
    ELSE
        RETURN NEW;
    END IF;

    IF v_is_company_fleet_asset = TRUE THEN
        IF v_event_type NOT IN ('DECOMMISSIONED', 'LOST_CONFIRMED') THEN
            RETURN NEW;
        END IF;

        v_before := public.fn_current_fleet_count();

        INSERT INTO public.tbl_cylinder_fleet_ledger (
            fk_cylinder, event_type, fleet_count_before, fleet_count_after, delta, remarks
        ) VALUES (
            NEW.fk_cylinder,
            v_event_type,
            v_before,
            v_before - 1,
            -1,
            COALESCE(NEW.remarks, 'Company fleet state transition to ' || v_new_state_name)
        );

        RETURN NEW;
    END IF;

    IF v_ownership_type_code IN ('SUPPLIER_OWNED', 'CUSTOMER_OWNED') THEN
        INSERT INTO public.tbl_external_cylinder_asset_ledger (
            fk_cylinder,
            fk_asset_ownership_type,
            fk_owner_supplier,
            fk_owner_customer,
            fk_product,
            cylinder_type,
            event_type,
            delta,
            remarks
        )
        SELECT c.pk_cylinder_id,
               c.fk_asset_ownership_type,
               c.fk_owner_supplier,
               c.fk_owner_customer,
               c.fk_product,
               NULL,
               CASE
                   WHEN v_ownership_type_code = 'SUPPLIER_OWNED' AND v_event_type = 'LOST_CONFIRMED'
                       THEN 'SUPPLIER_ASSET_LOST'
                   WHEN v_ownership_type_code = 'CUSTOMER_OWNED' AND v_event_type = 'LOST_CONFIRMED'
                       THEN 'CUSTOMER_ASSET_LOST'
                   WHEN v_ownership_type_code = 'SUPPLIER_OWNED' AND v_event_type = 'DAMAGED'
                       THEN 'SUPPLIER_ASSET_DAMAGED'
                   WHEN v_ownership_type_code = 'CUSTOMER_OWNED' AND v_event_type = 'DAMAGED'
                       THEN 'CUSTOMER_ASSET_DAMAGED'
                   WHEN v_ownership_type_code = 'SUPPLIER_OWNED'
                       THEN 'SUPPLIER_ASSET_DECOMMISSIONED'
                   ELSE 'CUSTOMER_ASSET_DECOMMISSIONED'
               END,
               CASE WHEN v_event_type IN ('DECOMMISSIONED', 'LOST_CONFIRMED') THEN -1 ELSE 0 END,
               COALESCE(NEW.remarks, 'External asset state transition to ' || v_new_state_name)
          FROM public.tbl_cylinder c
         WHERE c.pk_cylinder_id = NEW.fk_cylinder;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMIT;
