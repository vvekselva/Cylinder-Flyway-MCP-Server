-- =====================================================================
-- V123__Trip_Challan_Entry_Aging.sql
-- =====================================================================
--
-- Purpose:
--   Track whether challans for a vehicle load/trip are entered within
--   24 hours from load creation.
--
-- Business Meaning:
--   - Trip/load starts in the morning.
--   - Driver physically carries challans during the day.
--   - Office enters challans after the vehicle returns / challans are handed over.
--   - Until challans are entered, trip accounting remains incomplete.
--
-- This migration introduces a dedicated challan-entry tracker.
--
-- Status model:
--   PENDING   = load created, no challan entry completed yet
--   PARTIAL   = some challan/stop entries exist, but not completed
--   COMPLETED = challan entry completed
--   AGING     = not completed after load_created_at + 24 hours
--   ESCALATED = aging item escalated for investigation
--
-- Separation of concerns:
--   This table is NOT cylinder custody/obligation.
--   Cylinder obligation is represented by tbl_cylinder_party_custody.
-- =====================================================================


-- =====================================================================
-- 1. Sequence
-- =====================================================================

CREATE SEQUENCE IF NOT EXISTS public.pk_trip_challan_entry_tracker_id_serial
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


-- =====================================================================
-- 2. Main tracker table
-- =====================================================================

CREATE TABLE IF NOT EXISTS public.tbl_trip_challan_entry_tracker (
    pk_challan_entry_tracker_id BIGINT NOT NULL
        DEFAULT nextval('public.pk_trip_challan_entry_tracker_id_serial'),

    fk_vehicle_trip BIGINT NOT NULL,
    fk_vehicle_load BIGINT NOT NULL,

    tracker_status VARCHAR(30) NOT NULL DEFAULT 'PENDING',

    load_created_at TIMESTAMP NOT NULL,
    challan_due_at TIMESTAMP NOT NULL,

    first_challan_entered_at TIMESTAMP NULL,
    completed_at TIMESTAMP NULL,

    expected_stop_count INTEGER NULL,
    entered_stop_count INTEGER NOT NULL DEFAULT 0,

    expected_challan_count INTEGER NULL,
    entered_challan_count INTEGER NOT NULL DEFAULT 0,

    escalated_at TIMESTAMP NULL,
    escalation_remarks VARCHAR(1000) NULL,

    remarks VARCHAR(1000) NULL,

    created_at TIMESTAMP NOT NULL DEFAULT now(),
    updated_at TIMESTAMP NOT NULL DEFAULT now(),

    CONSTRAINT tbl_trip_challan_entry_tracker_pk
        PRIMARY KEY (pk_challan_entry_tracker_id),

    CONSTRAINT tbl_trip_challan_entry_tracker_trip_fk
        FOREIGN KEY (fk_vehicle_trip)
        REFERENCES public.tbl_vehicle_trip(pk_vehicle_trip_id),

    CONSTRAINT tbl_trip_challan_entry_tracker_load_fk
        FOREIGN KEY (fk_vehicle_load)
        REFERENCES public.tbl_vehicle_load(pk_vehicle_load_id),

    CONSTRAINT tbl_trip_challan_entry_tracker_status_chk
        CHECK (tracker_status IN (
            'PENDING',
            'PARTIAL',
            'COMPLETED',
            'AGING',
            'ESCALATED'
        )),

    CONSTRAINT tbl_trip_challan_entry_tracker_unique_load
        UNIQUE (fk_vehicle_load)
);


CREATE INDEX IF NOT EXISTS idx_trip_challan_tracker_trip
ON public.tbl_trip_challan_entry_tracker(fk_vehicle_trip);

CREATE INDEX IF NOT EXISTS idx_trip_challan_tracker_status_due
ON public.tbl_trip_challan_entry_tracker(tracker_status, challan_due_at);

CREATE INDEX IF NOT EXISTS idx_trip_challan_tracker_due_open
ON public.tbl_trip_challan_entry_tracker(challan_due_at)
WHERE tracker_status IN ('PENDING', 'PARTIAL', 'AGING');


-- =====================================================================
-- 3. Audit table
-- =====================================================================

CREATE SEQUENCE IF NOT EXISTS public.pk_trip_challan_entry_tracker_audit_id_serial
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


CREATE TABLE IF NOT EXISTS public.tbl_trip_challan_entry_tracker_audit (
    pk_challan_entry_tracker_audit_id BIGINT NOT NULL
        DEFAULT nextval('public.pk_trip_challan_entry_tracker_audit_id_serial'),

    fk_challan_entry_tracker BIGINT NOT NULL,

    fk_vehicle_trip BIGINT NULL,
    fk_vehicle_load BIGINT NULL,

    old_status VARCHAR(30) NULL,
    new_status VARCHAR(30) NULL,

    event_type VARCHAR(100) NOT NULL,
    source_entity_type VARCHAR(100) NULL,
    source_entity_id BIGINT NULL,

    event_message VARCHAR(1000) NULL,

    created_by VARCHAR(100) NOT NULL DEFAULT 'SYSTEM',
    created_at TIMESTAMP NOT NULL DEFAULT now(),

    CONSTRAINT tbl_trip_challan_entry_tracker_audit_pk
        PRIMARY KEY (pk_challan_entry_tracker_audit_id),

    CONSTRAINT tbl_trip_challan_entry_tracker_audit_tracker_fk
        FOREIGN KEY (fk_challan_entry_tracker)
        REFERENCES public.tbl_trip_challan_entry_tracker(pk_challan_entry_tracker_id)
);


CREATE INDEX IF NOT EXISTS idx_trip_challan_tracker_audit_tracker
ON public.tbl_trip_challan_entry_tracker_audit(fk_challan_entry_tracker);

CREATE INDEX IF NOT EXISTS idx_trip_challan_tracker_audit_trip
ON public.tbl_trip_challan_entry_tracker_audit(fk_vehicle_trip);

CREATE INDEX IF NOT EXISTS idx_trip_challan_tracker_audit_created_at
ON public.tbl_trip_challan_entry_tracker_audit(created_at);


-- =====================================================================
-- 4. Audit helper
-- =====================================================================

CREATE OR REPLACE FUNCTION public.fn_log_trip_challan_entry_tracker_audit(
    p_tracker_id BIGINT,
    p_vehicle_trip_id BIGINT,
    p_vehicle_load_id BIGINT,
    p_old_status VARCHAR,
    p_new_status VARCHAR,
    p_event_type VARCHAR,
    p_source_entity_type VARCHAR,
    p_source_entity_id BIGINT,
    p_event_message VARCHAR,
    p_created_by VARCHAR DEFAULT 'SYSTEM'
)
RETURNS VOID
LANGUAGE plpgsql
AS $function$
BEGIN
    IF p_tracker_id IS NULL THEN
        RETURN;
    END IF;

    INSERT INTO public.tbl_trip_challan_entry_tracker_audit (
        fk_challan_entry_tracker,
        fk_vehicle_trip,
        fk_vehicle_load,
        old_status,
        new_status,
        event_type,
        source_entity_type,
        source_entity_id,
        event_message,
        created_by
    ) VALUES (
        p_tracker_id,
        p_vehicle_trip_id,
        p_vehicle_load_id,
        p_old_status,
        p_new_status,
        p_event_type,
        p_source_entity_type,
        p_source_entity_id,
        p_event_message,
        COALESCE(p_created_by, 'SYSTEM')
    );
END;
$function$;


-- =====================================================================
-- 5. Create tracker when vehicle load is created
-- =====================================================================

CREATE OR REPLACE FUNCTION public.fn_create_trip_challan_entry_tracker()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $function$
DECLARE
    v_tracker_id BIGINT;
BEGIN
    IF NEW.fk_vehicle_trip IS NULL THEN
        RETURN NEW;
    END IF;

    INSERT INTO public.tbl_trip_challan_entry_tracker (
        fk_vehicle_trip,
        fk_vehicle_load,
        tracker_status,
        load_created_at,
        challan_due_at,
        remarks
    ) VALUES (
        NEW.fk_vehicle_trip,
        NEW.pk_vehicle_load_id,
        'PENDING',
        COALESCE(NEW.created_at, now()),
        COALESCE(NEW.created_at, now()) + interval '24 hours',
        'Challan entry tracker opened automatically on vehicle load creation.'
    )
    ON CONFLICT (fk_vehicle_load) DO NOTHING
    RETURNING pk_challan_entry_tracker_id INTO v_tracker_id;

    IF v_tracker_id IS NOT NULL THEN
        PERFORM public.fn_log_trip_challan_entry_tracker_audit(
            v_tracker_id,
            NEW.fk_vehicle_trip,
            NEW.pk_vehicle_load_id,
            NULL,
            'PENDING',
            'TRACKER_OPENED',
            'tbl_vehicle_load',
            NEW.pk_vehicle_load_id,
            'Challan entry tracker opened. Due at '
                || (COALESCE(NEW.created_at, now()) + interval '24 hours')::TEXT,
            'SYSTEM'
        );
    END IF;

    RETURN NEW;
END;
$function$;


DROP TRIGGER IF EXISTS trg_create_trip_challan_entry_tracker
ON public.tbl_vehicle_load;

CREATE TRIGGER trg_create_trip_challan_entry_tracker
AFTER INSERT
ON public.tbl_vehicle_load
FOR EACH ROW
EXECUTE FUNCTION public.fn_create_trip_challan_entry_tracker();


-- =====================================================================
-- 6. Mark tracker partial when stop/challan-like transaction is entered
-- =====================================================================

CREATE OR REPLACE FUNCTION public.fn_mark_trip_challan_entry_partial(
    p_vehicle_trip_id BIGINT,
    p_vehicle_load_id BIGINT,
    p_source_entity_type VARCHAR,
    p_source_entity_id BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
AS $function$
DECLARE
    v_tracker RECORD;
    v_old_status VARCHAR(30);
    v_new_status VARCHAR(30);
BEGIN
    IF p_vehicle_trip_id IS NULL THEN
        RETURN;
    END IF;

    SELECT *
      INTO v_tracker
      FROM public.tbl_trip_challan_entry_tracker
     WHERE fk_vehicle_trip = p_vehicle_trip_id
       AND (p_vehicle_load_id IS NULL OR fk_vehicle_load = p_vehicle_load_id)
     ORDER BY pk_challan_entry_tracker_id DESC
     LIMIT 1;

    IF v_tracker.pk_challan_entry_tracker_id IS NULL THEN
        RETURN;
    END IF;

    v_old_status := v_tracker.tracker_status;

    IF v_old_status IN ('COMPLETED', 'ESCALATED') THEN
        RETURN;
    END IF;

    v_new_status := CASE
        WHEN now() > v_tracker.challan_due_at THEN 'AGING'
        ELSE 'PARTIAL'
    END;

    UPDATE public.tbl_trip_challan_entry_tracker
       SET tracker_status = v_new_status,
           first_challan_entered_at = COALESCE(first_challan_entered_at, now()),
           entered_stop_count = COALESCE(entered_stop_count, 0) + 1,
           entered_challan_count = COALESCE(entered_challan_count, 0) + 1,
           updated_at = now()
     WHERE pk_challan_entry_tracker_id = v_tracker.pk_challan_entry_tracker_id;

    PERFORM public.fn_log_trip_challan_entry_tracker_audit(
        v_tracker.pk_challan_entry_tracker_id,
        v_tracker.fk_vehicle_trip,
        v_tracker.fk_vehicle_load,
        v_old_status,
        v_new_status,
        'CHALLAN_ENTRY_PARTIAL',
        p_source_entity_type,
        p_source_entity_id,
        'A challan/stop transaction was entered. Tracker marked '
            || v_new_status,
        'SYSTEM'
    );
END;
$function$;


-- =====================================================================
-- 7. Source triggers for partial entry
-- =====================================================================

CREATE OR REPLACE FUNCTION public.fn_mark_challan_partial_from_supplier_trip()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $function$
BEGIN
    PERFORM public.fn_mark_trip_challan_entry_partial(
        NEW.fk_vehicle_trip,
        NEW.fk_vehicle_load,
        'tbl_supplier_trip',
        NEW.pk_supplier_trip_id
    );

    RETURN NEW;
END;
$function$;


DROP TRIGGER IF EXISTS trg_mark_challan_partial_from_supplier_trip
ON public.tbl_supplier_trip;

CREATE TRIGGER trg_mark_challan_partial_from_supplier_trip
AFTER INSERT
ON public.tbl_supplier_trip
FOR EACH ROW
EXECUTE FUNCTION public.fn_mark_challan_partial_from_supplier_trip();


CREATE OR REPLACE FUNCTION public.fn_mark_challan_partial_from_order()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $function$
DECLARE
    v_trip_id BIGINT;
    v_load_id BIGINT;
BEGIN
    v_trip_id := public.fn_try_read_bigint_column(
        'tbl_order',
        'pk_order_id',
        NEW.pk_order_id,
        'fk_vehicle_trip'
    );

    v_load_id := public.fn_try_read_bigint_column(
        'tbl_order',
        'pk_order_id',
        NEW.pk_order_id,
        'fk_vehicle_load'
    );

    PERFORM public.fn_mark_trip_challan_entry_partial(
        v_trip_id,
        v_load_id,
        'tbl_order',
        NEW.pk_order_id
    );

    RETURN NEW;
END;
$function$;


DROP TRIGGER IF EXISTS trg_mark_challan_partial_from_order
ON public.tbl_order;

CREATE TRIGGER trg_mark_challan_partial_from_order
AFTER INSERT
ON public.tbl_order
FOR EACH ROW
EXECUTE FUNCTION public.fn_mark_challan_partial_from_order();


CREATE OR REPLACE FUNCTION public.fn_mark_challan_partial_from_empty_pickup()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $function$
DECLARE
    v_trip_id BIGINT;
    v_load_id BIGINT;
BEGIN
    v_trip_id := public.fn_try_read_bigint_column(
        'tbl_empty_pickup',
        'pk_empty_pickup_id',
        NEW.pk_empty_pickup_id,
        'fk_vehicle_trip'
    );

    v_load_id := public.fn_try_read_bigint_column(
        'tbl_empty_pickup',
        'pk_empty_pickup_id',
        NEW.pk_empty_pickup_id,
        'fk_vehicle_load'
    );

    PERFORM public.fn_mark_trip_challan_entry_partial(
        v_trip_id,
        v_load_id,
        'tbl_empty_pickup',
        NEW.pk_empty_pickup_id
    );

    RETURN NEW;
END;
$function$;


DROP TRIGGER IF EXISTS trg_mark_challan_partial_from_empty_pickup
ON public.tbl_empty_pickup;

CREATE TRIGGER trg_mark_challan_partial_from_empty_pickup
AFTER INSERT
ON public.tbl_empty_pickup
FOR EACH ROW
EXECUTE FUNCTION public.fn_mark_challan_partial_from_empty_pickup();


-- =====================================================================
-- 8. Aging recompute function
-- =====================================================================

CREATE OR REPLACE FUNCTION public.fn_refresh_trip_challan_entry_aging()
RETURNS INTEGER
LANGUAGE plpgsql
AS $function$
DECLARE
    v_count INTEGER := 0;
    v_row RECORD;
BEGIN
    FOR v_row IN
        SELECT *
          FROM public.tbl_trip_challan_entry_tracker
         WHERE tracker_status IN ('PENDING', 'PARTIAL')
           AND now() > challan_due_at
    LOOP
        UPDATE public.tbl_trip_challan_entry_tracker
           SET tracker_status = 'AGING',
               updated_at = now()
         WHERE pk_challan_entry_tracker_id = v_row.pk_challan_entry_tracker_id;

        PERFORM public.fn_log_trip_challan_entry_tracker_audit(
            v_row.pk_challan_entry_tracker_id,
            v_row.fk_vehicle_trip,
            v_row.fk_vehicle_load,
            v_row.tracker_status,
            'AGING',
            'CHALLAN_ENTRY_AGING',
            'tbl_trip_challan_entry_tracker',
            v_row.pk_challan_entry_tracker_id,
            'Challan entry exceeded 24-hour SLA.',
            'SYSTEM'
        );

        v_count := v_count + 1;
    END LOOP;

    RETURN v_count;
END;
$function$;


-- =====================================================================
-- 9. Completion helper
-- =====================================================================

CREATE OR REPLACE FUNCTION public.fn_complete_trip_challan_entry_tracker(
    p_vehicle_trip_id BIGINT,
    p_vehicle_load_id BIGINT,
    p_source_entity_type VARCHAR DEFAULT 'MANUAL',
    p_source_entity_id BIGINT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
AS $function$
DECLARE
    v_tracker RECORD;
    v_old_status VARCHAR(30);
BEGIN
    SELECT *
      INTO v_tracker
      FROM public.tbl_trip_challan_entry_tracker
     WHERE fk_vehicle_trip = p_vehicle_trip_id
       AND (p_vehicle_load_id IS NULL OR fk_vehicle_load = p_vehicle_load_id)
     ORDER BY pk_challan_entry_tracker_id DESC
     LIMIT 1;

    IF v_tracker.pk_challan_entry_tracker_id IS NULL THEN
        RETURN;
    END IF;

    v_old_status := v_tracker.tracker_status;

    UPDATE public.tbl_trip_challan_entry_tracker
       SET tracker_status = 'COMPLETED',
           completed_at = now(),
           updated_at = now(),
           remarks = COALESCE(remarks, '')
               || ' Challan entry completed.'
     WHERE pk_challan_entry_tracker_id = v_tracker.pk_challan_entry_tracker_id;

    PERFORM public.fn_log_trip_challan_entry_tracker_audit(
        v_tracker.pk_challan_entry_tracker_id,
        v_tracker.fk_vehicle_trip,
        v_tracker.fk_vehicle_load,
        v_old_status,
        'COMPLETED',
        'CHALLAN_ENTRY_COMPLETED',
        p_source_entity_type,
        p_source_entity_id,
        'Challan entry marked completed.',
        'SYSTEM'
    );
END;
$function$;


-- =====================================================================
-- 10. Backfill trackers for existing loads
-- =====================================================================

INSERT INTO public.tbl_trip_challan_entry_tracker (
    fk_vehicle_trip,
    fk_vehicle_load,
    tracker_status,
    load_created_at,
    challan_due_at,
    remarks
)
SELECT
    vl.fk_vehicle_trip,
    vl.pk_vehicle_load_id,
    'PENDING',
    COALESCE(vl.created_at, now()),
    COALESCE(vl.created_at, now()) + interval '24 hours',
    'Backfilled challan entry tracker.'
FROM public.tbl_vehicle_load vl
WHERE vl.fk_vehicle_trip IS NOT NULL
  AND NOT EXISTS (
      SELECT 1
        FROM public.tbl_trip_challan_entry_tracker existing
       WHERE existing.fk_vehicle_load = vl.pk_vehicle_load_id
  );


-- =====================================================================
-- Documentation
-- =====================================================================

COMMENT ON TABLE public.tbl_trip_challan_entry_tracker IS
'Tracks 24-hour challan entry aging from vehicle load creation. Separate from cylinder party custody/obligation.';

COMMENT ON COLUMN public.tbl_trip_challan_entry_tracker.tracker_status IS
'PENDING, PARTIAL, COMPLETED, AGING, ESCALATED. PENDING begins at vehicle load creation. AGING begins after 24 hours if not completed.';

COMMENT ON FUNCTION public.fn_refresh_trip_challan_entry_aging() IS
'Marks PENDING/PARTIAL challan entry trackers as AGING when now() exceeds challan_due_at. Intended for scheduler/manual execution.';

COMMENT ON FUNCTION public.fn_complete_trip_challan_entry_tracker(BIGINT, BIGINT, VARCHAR, BIGINT) IS
'Marks challan entry tracker as COMPLETED for a trip/load after office challan entry is finished.';


DO $$
BEGIN
    RAISE NOTICE 'V123 OK: Trip challan entry aging tracker installed.';
    RAISE NOTICE 'V123 OK: 24-hour challan aging starts from vehicle load creation.';
END $$;
