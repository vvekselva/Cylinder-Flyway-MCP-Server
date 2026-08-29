-- =============================================================================
-- V110__WalkInPickup_For_Empty_Returns.sql
-- =============================================================================
--
-- PURPOSE
-- ─────────────────────────────────────────────────────────────────────────────
-- Adds the missing walk-in empty pickup workflow.
--
-- Correct lifecycle:
--   1. Walk-in delivery/order line:
--        FULL → DELIVERED_FOR_CONSUMPTION
--
--   2. Walk-in pickup line:
--        DELIVERED_FOR_CONSUMPTION → EMPTY_IN_TRANSIT_TO_YARD
--
--   3. Yard entry:
--        EMPTY_IN_TRANSIT_TO_YARD → EMPTY
--
-- WHY
-- ─────────────────────────────────────────────────────────────────────────────
-- tbl_yard_entries must not accept DELIVERED_FOR_CONSUMPTION directly because
-- yard entry represents physical yard receipt, not customer pickup.
-- This migration introduces the pickup event before yard receipt.
-- =============================================================================


-- =============================================================================
-- STEP 1 — Sequences
-- =============================================================================

CREATE SEQUENCE IF NOT EXISTS public.pk_walk_in_pickup_id_serial
    INCREMENT BY 1
    MINVALUE 1
    MAXVALUE 9223372036854775807
    START 1
    CACHE 1
    NO CYCLE;

CREATE SEQUENCE IF NOT EXISTS public.pk_walk_in_pickup_line_id_serial
    INCREMENT BY 1
    MINVALUE 1
    MAXVALUE 9223372036854775807
    START 1
    CACHE 1
    NO CYCLE;


-- =============================================================================
-- STEP 2 — Header table: tbl_walk_in_pickup
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.tbl_walk_in_pickup (
    pk_walk_in_pickup_id int8 DEFAULT nextval('public.pk_walk_in_pickup_id_serial'::regclass) NOT NULL,
    fk_customer          int8 NOT NULL,
    picked_by            varchar(200) NOT NULL,
    pickup_date          date DEFAULT CURRENT_DATE NOT NULL,
    pickup_status        varchar(20) DEFAULT 'OPEN'::varchar NOT NULL,
    total_cylinders      int4 DEFAULT 0 NOT NULL,
    remarks              varchar(500) NULL,
    created_at           timestamp DEFAULT now() NOT NULL,
    updated_at           timestamp NULL,

    CONSTRAINT tbl_walk_in_pickup_pk PRIMARY KEY (pk_walk_in_pickup_id),
    CONSTRAINT tbl_walk_in_pickup_customer_fk
        FOREIGN KEY (fk_customer)
        REFERENCES public.tbl_customer(pk_customer_id),
    CONSTRAINT tbl_walk_in_pickup_status_chk
        CHECK (pickup_status IN ('OPEN', 'COMPLETED', 'CANCELLED')),
    CONSTRAINT tbl_walk_in_pickup_total_chk
        CHECK (total_cylinders >= 0)
);

CREATE INDEX IF NOT EXISTS idx_walk_in_pickup_customer
    ON public.tbl_walk_in_pickup USING btree (fk_customer, pickup_date DESC);

CREATE INDEX IF NOT EXISTS idx_walk_in_pickup_date_open
    ON public.tbl_walk_in_pickup USING btree (pickup_date DESC)
    WHERE pickup_status = 'OPEN';


-- =============================================================================
-- STEP 3 — Line table: tbl_walk_in_pickup_line
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.tbl_walk_in_pickup_line (
    pk_walk_in_pickup_line_id int8 DEFAULT nextval('public.pk_walk_in_pickup_line_id_serial'::regclass) NOT NULL,
    fk_walk_in_pickup         int8 NOT NULL,
    fk_cylinder               int8 NOT NULL,
    picked_at                 timestamp DEFAULT now() NOT NULL,
    remarks                   varchar(500) NULL,

    CONSTRAINT tbl_walk_in_pickup_line_pk PRIMARY KEY (pk_walk_in_pickup_line_id),
    CONSTRAINT tbl_walk_in_pickup_line_pickup_fk
        FOREIGN KEY (fk_walk_in_pickup)
        REFERENCES public.tbl_walk_in_pickup(pk_walk_in_pickup_id),
    CONSTRAINT tbl_walk_in_pickup_line_cylinder_fk
        FOREIGN KEY (fk_cylinder)
        REFERENCES public.tbl_cylinder(pk_cylinder_id),
    CONSTRAINT tbl_walk_in_pickup_line_unique
        UNIQUE (fk_walk_in_pickup, fk_cylinder)
);

CREATE INDEX IF NOT EXISTS idx_walk_in_pickup_line_pickup
    ON public.tbl_walk_in_pickup_line USING btree (fk_walk_in_pickup);

CREATE INDEX IF NOT EXISTS idx_walk_in_pickup_line_cylinder
    ON public.tbl_walk_in_pickup_line USING btree (fk_cylinder);


-- =============================================================================
-- STEP 4 — State transition seed
-- =============================================================================
INSERT INTO public.tbl_cylinder_state_transition (
    from_state,
    to_state,
    description
)
SELECT
    'DELIVERED_FOR_CONSUMPTION',
    'EMPTY_IN_TRANSIT_TO_YARD',
    'Walk-in empty cylinder picked up from customer and moved towards yard.'
WHERE NOT EXISTS (
    SELECT 1
      FROM public.tbl_cylinder_state_transition
     WHERE from_state = 'DELIVERED_FOR_CONSUMPTION'
       AND to_state   = 'EMPTY_IN_TRANSIT_TO_YARD'
);

-- =============================================================================
-- STEP 5 — Trigger function: pickup line changes state to EMPTY_IN_TRANSIT_TO_YARD
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_walk_in_pickup_line_after_insert()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_customer_id                 int8;
    v_previous_state_id           int8;
    v_previous_state_name         varchar(100);
    v_empty_in_transit_state_id   int8;
    v_yard_location_id            int8;
    v_cylinder_serial             varchar(100);
BEGIN
    -- Resolve pickup customer.
    SELECT fk_customer
      INTO v_customer_id
      FROM public.tbl_walk_in_pickup
     WHERE pk_walk_in_pickup_id = NEW.fk_walk_in_pickup;

    IF v_customer_id IS NULL THEN
        RAISE EXCEPTION
            'Walk-in pickup validation failed: pickup header % not found.',
            NEW.fk_walk_in_pickup;
    END IF;

    -- Resolve current cylinder state and holder.
    SELECT ccs.fk_current_state, cs.cylinder_state
      INTO v_previous_state_id, v_previous_state_name
      FROM public.tbl_cylinder_current_status ccs
      JOIN public.tbl_cylinder_states cs
        ON cs.pk_cylinder_state_id = ccs.fk_current_state
     WHERE ccs.fk_cylinder = NEW.fk_cylinder
       AND ccs.fk_current_holder_customer = v_customer_id;

    IF NOT FOUND THEN
        SELECT cylinder_serial
          INTO v_cylinder_serial
          FROM public.tbl_cylinder
         WHERE pk_cylinder_id = NEW.fk_cylinder;

        RAISE EXCEPTION
            'Walk-in pickup validation failed: cylinder % (%) is not currently held by customer %.',
            COALESCE(v_cylinder_serial, '?'),
            NEW.fk_cylinder,
            v_customer_id;
    END IF;

    IF v_previous_state_name <> 'DELIVERED_FOR_CONSUMPTION' THEN
        SELECT cylinder_serial
          INTO v_cylinder_serial
          FROM public.tbl_cylinder
         WHERE pk_cylinder_id = NEW.fk_cylinder;

        RAISE EXCEPTION
            'Walk-in pickup validation failed: cylinder % (%) is in state [%]. Expected state [DELIVERED_FOR_CONSUMPTION] before pickup.',
            COALESCE(v_cylinder_serial, '?'),
            NEW.fk_cylinder,
            COALESCE(v_previous_state_name, 'UNKNOWN');
    END IF;

    SELECT pk_cylinder_state_id
      INTO v_empty_in_transit_state_id
      FROM public.tbl_cylinder_states
     WHERE cylinder_state = 'EMPTY_IN_TRANSIT_TO_YARD';

    IF v_empty_in_transit_state_id IS NULL THEN
        RAISE EXCEPTION
            'Walk-in pickup validation failed: cylinder state EMPTY_IN_TRANSIT_TO_YARD is missing.';
    END IF;

    -- Use Yard location as the destination bucket for the return-to-yard leg.
    SELECT pk_location_id
      INTO v_yard_location_id
      FROM public.tbl_cylinder_location
     WHERE location_name IN ('Yard', 'Yard Location')
     ORDER BY CASE WHEN location_name = 'Yard' THEN 1 ELSE 2 END
     LIMIT 1;

    IF v_yard_location_id IS NULL THEN
        RAISE EXCEPTION
            'Walk-in pickup validation failed: Yard location not found in tbl_cylinder_location.';
    END IF;

    -- Audit pickup transition.
    INSERT INTO public.tbl_cylinder_state_audit (
        pk_audit_id,
        fk_cylinder,
        fk_previous_state,
        fk_new_state,
        changed_at,
        remarks
    ) VALUES (
        nextval('public.pk_cylinder_state_id_serial'),
        NEW.fk_cylinder,
        v_previous_state_id,
        v_empty_in_transit_state_id,
        now(),
        'Walk-in empty pickup. State: DELIVERED_FOR_CONSUMPTION → EMPTY_IN_TRANSIT_TO_YARD. Pickup id: '
        || NEW.fk_walk_in_pickup
    );

    -- Move out of customer holding and into return-to-yard state.
    UPDATE public.tbl_cylinder_current_status
       SET fk_current_state            = v_empty_in_transit_state_id,
           fk_current_location         = v_yard_location_id,
           fk_current_holder_customer  = NULL,
           fk_current_customer_address = NULL,
           fk_current_supplier         = NULL,
           fk_current_vehicle_trip     = NULL,
           fk_current_vehicle_load     = NULL,
           updated_at                  = now()
     WHERE fk_cylinder = NEW.fk_cylinder;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.fn_walk_in_pickup_line_after_insert() IS
    'Walk-in empty pickup transition. Validates customer holding and state DELIVERED_FOR_CONSUMPTION, then changes cylinder to EMPTY_IN_TRANSIT_TO_YARD so tbl_yard_entries can safely complete EMPTY yard receipt.';


-- =============================================================================
-- STEP 6 — Trigger binding
-- =============================================================================

DROP TRIGGER IF EXISTS trg_walk_in_pickup_line_after_insert
ON public.tbl_walk_in_pickup_line;

CREATE TRIGGER trg_walk_in_pickup_line_after_insert
AFTER INSERT ON public.tbl_walk_in_pickup_line
FOR EACH ROW
EXECUTE FUNCTION public.fn_walk_in_pickup_line_after_insert();


-- =============================================================================
-- STEP 7 — Verification
-- =============================================================================

DO $$
DECLARE
    v_header_exists boolean;
    v_line_exists   boolean;
    v_trigger_exists boolean;
BEGIN
    SELECT EXISTS (
        SELECT 1
          FROM information_schema.tables
         WHERE table_schema = 'public'
           AND table_name = 'tbl_walk_in_pickup'
    )
    INTO v_header_exists;

    SELECT EXISTS (
        SELECT 1
          FROM information_schema.tables
         WHERE table_schema = 'public'
           AND table_name = 'tbl_walk_in_pickup_line'
    )
    INTO v_line_exists;

    SELECT EXISTS (
        SELECT 1
          FROM pg_trigger
         WHERE tgname = 'trg_walk_in_pickup_line_after_insert'
    )
    INTO v_trigger_exists;

    IF NOT v_header_exists THEN
        RAISE WARNING 'V110 VERIFY FAILED: tbl_walk_in_pickup missing.';
    ELSE
        RAISE NOTICE 'V110 OK: tbl_walk_in_pickup exists.';
    END IF;

    IF NOT v_line_exists THEN
        RAISE WARNING 'V110 VERIFY FAILED: tbl_walk_in_pickup_line missing.';
    ELSE
        RAISE NOTICE 'V110 OK: tbl_walk_in_pickup_line exists.';
    END IF;

    IF NOT v_trigger_exists THEN
        RAISE WARNING 'V110 VERIFY FAILED: trg_walk_in_pickup_line_after_insert missing.';
    ELSE
        RAISE NOTICE 'V110 OK: walk-in pickup line trigger exists.';
    END IF;
END;
$$;
