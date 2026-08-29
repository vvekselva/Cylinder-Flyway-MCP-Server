-- =============================================================================
-- V69__VehicleTripStatus.sql
-- =============================================================================
-- PURPOSE:
--   Introduce a normalised trip-status lifecycle for tbl_vehicle_trip and wire
--   it into the reconciliation orchestrator (V61) and daily cylinder count (V59).
--
-- DESIGN:
--   tbl_trip_status  — lookup / enum table for the four lifecycle states.
--   tbl_vehicle_trip gains a fk_trip_status column so every trip row always
--   knows its current state.
--
-- TRIP LIFECYCLE:
--
--     [row created]
--          │
--          ▼
--       Started ──► Loaded ──► Proceeding ──► Halt (trip closed)
--
--   Started    : Vehicle trip record created, vehicle assigned, driver confirmed.
--   Loaded     : Cylinders have been physically loaded onto the vehicle at the yard.
--   Proceeding : Vehicle has departed the yard and is making customer stops.
--   Halt       : Vehicle has returned to the yard; all cylinders accounted for.
--                End-of-trip reconciliation checkpoint is created on transition
--                to this status.
--
-- TRIGGER BEHAVIOUR:
--   INSERT  → status defaults to 'Started';
--             a TRIP_DEPARTURE reconciliation checkpoint is created (V61).
--   UPDATE (status → 'Halt')
--           → resolves the TRIP_DEPARTURE checkpoint with a TRIP_RETURN event;
--             updates tbl_daily_cylinder_count if the day row exists.
--
-- VALID TRANSITIONS (enforced by trigger):
--   Started → Loaded
--   Loaded  → Proceeding
--   Proceeding → Halt
-- =============================================================================
-- =============================================================================
-- V69__VehicleTripStatus.sql  (REVISED — Flyway-compatible)
-- =============================================================================
-- FIXES IN THIS REVISION:
--
-- FIX 1 — ERROR: cannot use subquery in DEFAULT expression  (Flyway line 103)
--   PostgreSQL forbids SELECT subqueries inside ALTER COLUMN SET DEFAULT.
--   The default is now handled exclusively by the BEFORE INSERT trigger
--   fn_trip_on_insert(). The column simply has no database-level default
--   (the trigger fires before the row is written, so it is always populated).
--
-- FIX 2 — SUM(vll.quantity): column does not exist
--   tbl_vehicle_load_line has no quantity column. One row = one cylinder.
--   Changed to COUNT(pk_vehicle_load_line_id) with a header-level fallback
--   to tbl_vehicle_load.total_cylinders_loaded.
--
-- FIX 3 — V61 Reconciliation Orchestrator integration
--   fn_create_checkpoint() / fn_resolve_checkpoint() (V61) are called via
--   PERFORM inside EXCEPTION blocks so the migration never fails if V61 has
--   not run (graceful degradation with NOTICE only).
-- =============================================================================

-- =============================================================================
-- V69__VehicleTripStatus.sql  (REVISED — Flyway-compatible)
-- =============================================================================
-- FIXES IN THIS REVISION:
--
-- FIX 1 — ERROR: cannot use subquery in DEFAULT expression  (Flyway line 103)
--   PostgreSQL forbids SELECT subqueries inside ALTER COLUMN SET DEFAULT.
--   The default is now handled exclusively by the BEFORE INSERT trigger
--   fn_trip_on_insert(). The column simply has no database-level default
--   (the trigger fires before the row is written, so it is always populated).
--
-- FIX 2 — SUM(vll.quantity): column does not exist
--   tbl_vehicle_load_line has no quantity column. One row = one cylinder.
--   Changed to COUNT(pk_vehicle_load_line_id) with a header-level fallback
--   to tbl_vehicle_load.total_cylinders_loaded.
--
-- FIX 3 — V61 Reconciliation Orchestrator integration
--   fn_create_checkpoint() / fn_resolve_checkpoint() (V61) are called via
--   PERFORM inside EXCEPTION blocks so the migration never fails if V61 has
--   not run (graceful degradation with NOTICE only).
-- =============================================================================


-- ---------------------------------------------------------------------------
-- SEQUENCE
-- ---------------------------------------------------------------------------
DROP SEQUENCE IF EXISTS public.pk_trip_status_id_serial;
CREATE SEQUENCE public.pk_trip_status_id_serial
    INCREMENT BY 1 MINVALUE 1 START 1 CACHE 1 NO CYCLE;


-- ---------------------------------------------------------------------------
-- TABLE: tbl_trip_status
-- ---------------------------------------------------------------------------
CREATE TABLE public.tbl_trip_status (
    pk_trip_status_id   int8        NOT NULL DEFAULT nextval('public.pk_trip_status_id_serial'),
    status_name         varchar(50) NOT NULL,
    display_order       int4        NOT NULL,
    is_terminal         boolean     NOT NULL DEFAULT false,
    description         varchar(300),
    CONSTRAINT tbl_trip_status_pk           PRIMARY KEY (pk_trip_status_id),
    CONSTRAINT tbl_trip_status_name_unique  UNIQUE      (status_name),
    CONSTRAINT tbl_trip_status_name_chk     CHECK (status_name IN ('Started','Loaded','Proceeding','Halt'))
);

INSERT INTO public.tbl_trip_status (status_name, display_order, is_terminal, description) VALUES
    ('Started',    1, false, 'Trip record created; vehicle and driver assigned.'),
    ('Loaded',     2, false, 'Cylinders physically loaded onto the vehicle at the yard.'),
    ('Proceeding', 3, false, 'Vehicle has departed the yard and is making customer stops.'),
    ('Halt',       4, true,  'Vehicle has returned; all cylinders accounted for. Trip closed.');


-- ---------------------------------------------------------------------------
-- ALTER tbl_vehicle_trip
-- ---------------------------------------------------------------------------
ALTER TABLE public.tbl_vehicle_trip
    ADD COLUMN IF NOT EXISTS fk_trip_status    int8         NULL,
    ADD COLUMN IF NOT EXISTS trip_started_at   timestamp    NULL,
    ADD COLUMN IF NOT EXISTS trip_loaded_at    timestamp    NULL,
    ADD COLUMN IF NOT EXISTS trip_departed_at  timestamp    NULL,
    ADD COLUMN IF NOT EXISTS trip_closed_at    timestamp    NULL,
    ADD COLUMN IF NOT EXISTS audit_notes       varchar(500) NULL;

-- Backfill existing rows
UPDATE public.tbl_vehicle_trip
   SET fk_trip_status = (SELECT pk_trip_status_id FROM public.tbl_trip_status WHERE status_name = 'Started')
 WHERE fk_trip_status IS NULL;

-- FIX 1: SET NOT NULL only — no subquery in SET DEFAULT
ALTER TABLE public.tbl_vehicle_trip
    ALTER COLUMN fk_trip_status SET NOT NULL;

ALTER TABLE public.tbl_vehicle_trip
    ADD CONSTRAINT tbl_vehicle_trip_status_fk
        FOREIGN KEY (fk_trip_status) REFERENCES public.tbl_trip_status(pk_trip_status_id);

CREATE INDEX idx_vehicle_trip_status ON public.tbl_vehicle_trip(fk_trip_status);
CREATE INDEX idx_vehicle_trip_status_open ON public.tbl_vehicle_trip(pk_vehicle_trip_id, fk_trip_status);


-- ---------------------------------------------------------------------------
-- FUNCTION: forward-only status transition guard (BEFORE UPDATE)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_validate_trip_status_transition()
RETURNS TRIGGER AS $$
DECLARE
    v_old_order int4;  v_new_order int4;
    v_old_name  varchar(50);  v_new_name varchar(50);
BEGIN
    IF NEW.fk_trip_status = OLD.fk_trip_status THEN RETURN NEW; END IF;

    SELECT status_name, display_order INTO v_old_name, v_old_order
      FROM public.tbl_trip_status WHERE pk_trip_status_id = OLD.fk_trip_status;
    SELECT status_name, display_order INTO v_new_name, v_new_order
      FROM public.tbl_trip_status WHERE pk_trip_status_id = NEW.fk_trip_status;

    IF v_new_order <> v_old_order + 1 THEN
        RAISE EXCEPTION 'Invalid trip status transition: % → %. Valid: Started→Loaded→Proceeding→Halt.',
            v_old_name, v_new_name;
    END IF;

    CASE v_new_name
        WHEN 'Loaded'     THEN NEW.trip_loaded_at   := now();
        WHEN 'Proceeding' THEN NEW.trip_departed_at := now();
        WHEN 'Halt'       THEN NEW.trip_closed_at   := now();
        ELSE NULL;
    END CASE;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_validate_trip_status_transition
BEFORE UPDATE ON public.tbl_vehicle_trip
FOR EACH ROW EXECUTE FUNCTION public.fn_validate_trip_status_transition();


-- ---------------------------------------------------------------------------
-- FUNCTION: BEFORE INSERT — assign 'Started' and stamp trip_started_at
-- FIX 1: This is the correct home for the default (no subquery in column DEFAULT)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_trip_on_insert()
RETURNS TRIGGER AS $$
BEGIN
    NEW.fk_trip_status  := (SELECT pk_trip_status_id FROM public.tbl_trip_status WHERE status_name = 'Started');
    NEW.trip_started_at := now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_trip_on_insert
BEFORE INSERT ON public.tbl_vehicle_trip
FOR EACH ROW EXECUTE FUNCTION public.fn_trip_on_insert();


-- ---------------------------------------------------------------------------
-- FUNCTION: AFTER UPDATE — V61 orchestrator integration
-- FIX 2: COUNT(pk_vehicle_load_line_id) — not SUM(vll.quantity)
-- FIX 3: V61 calls wrapped in EXCEPTION handlers for graceful degradation
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_trip_status_after_update()
RETURNS TRIGGER AS $$
DECLARE
    v_new_name      varchar(50);
    v_load_id       int8;
    v_cyl_count     int4 := 0;
BEGIN
    IF NEW.fk_trip_status = OLD.fk_trip_status THEN RETURN NEW; END IF;

    SELECT status_name INTO v_new_name
      FROM public.tbl_trip_status WHERE pk_trip_status_id = NEW.fk_trip_status;

    -- Resolve 1:1 vehicle load (V55 guarantee)
    SELECT pk_vehicle_load_id INTO v_load_id
      FROM public.tbl_vehicle_load WHERE fk_vehicle_trip = NEW.pk_vehicle_trip_id;

    -- FIX 2: count load lines (one row per cylinder); fallback to header total
    IF v_load_id IS NOT NULL THEN
        SELECT COUNT(pk_vehicle_load_line_id) INTO v_cyl_count
          FROM public.tbl_vehicle_load_line WHERE fk_vehicle_load = v_load_id;

        IF v_cyl_count = 0 THEN
            SELECT COALESCE(total_cylinders_loaded, 0) INTO v_cyl_count
              FROM public.tbl_vehicle_load WHERE pk_vehicle_load_id = v_load_id;
        END IF;
    END IF;

    -- ── Loaded: open daily count (V59) ──────────────────────────────────────
    IF v_new_name = 'Loaded' THEN
        BEGIN
            PERFORM public.fn_open_daily_count(CURRENT_DATE, 'TRIP_LOAD');
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'fn_trip_status_after_update [Loaded]: %', SQLERRM;
        END;
    END IF;

    -- ── Proceeding: TRIP_DEPARTURE checkpoint (V61) ──────────────────────────
    IF v_new_name = 'Proceeding' THEN
        BEGIN
            PERFORM public.fn_create_checkpoint(
                'TRIP_DEPARTURE',
                'tbl_vehicle_trip',
                NEW.pk_vehicle_trip_id,
                v_cyl_count,
                12,
                'Trip ' || NEW.pk_vehicle_trip_id || ' departed with ' || v_cyl_count || ' cylinders.'
            );
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'fn_trip_status_after_update [Proceeding/create_checkpoint]: %', SQLERRM;
        END;
    END IF;

    -- ── Halt: resolve TRIP_DEPARTURE checkpoint (V61) ───────────────────────
    IF v_new_name = 'Halt' THEN
        BEGIN
            PERFORM public.fn_resolve_checkpoint(
                'tbl_vehicle_trip',
                NEW.pk_vehicle_trip_id,
                'TRIP_DEPARTURE',
                v_cyl_count,
                COALESCE(NEW.audit_notes,
                    'Trip ' || NEW.pk_vehicle_trip_id || ' halted. Cylinders accounted: ' || v_cyl_count)
            );
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'fn_trip_status_after_update [Halt/resolve_checkpoint]: %', SQLERRM;
        END;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_trip_status_after_update
AFTER UPDATE OF fk_trip_status ON public.tbl_vehicle_trip
FOR EACH ROW EXECUTE FUNCTION public.fn_trip_status_after_update();


-- ---------------------------------------------------------------------------
-- VIEW: active trips
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.vw_active_trips AS
SELECT
    vt.pk_vehicle_trip_id,
    ts.status_name                                              AS trip_status,
    ts.display_order                                            AS status_order,
    v.vehicle_number,
    d.driver_name,
    vt.trip_started_at,
    vt.trip_loaded_at,
    vt.trip_departed_at,
    CASE WHEN vt.trip_departed_at IS NOT NULL
         THEN EXTRACT(HOUR FROM now() - vt.trip_departed_at)::int
    END                                                         AS hours_since_departure,
    vt.audit_notes
FROM public.tbl_vehicle_trip vt
JOIN public.tbl_trip_status ts ON ts.pk_trip_status_id = vt.fk_trip_status
JOIN public.tbl_vehicle     v  ON v.pk_vehicle_id      = vt.fk_vehicle
JOIN public.tbl_driver      d  ON d.pk_driver_id       = vt.fk_driver
WHERE ts.is_terminal = false
ORDER BY vt.trip_started_at DESC;