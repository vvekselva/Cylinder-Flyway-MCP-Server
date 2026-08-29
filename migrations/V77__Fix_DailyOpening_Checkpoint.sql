-- =============================================================================
-- V77__Fix_DailyOpening_Checkpoint.sql
-- =============================================================================
-- PROBLEM:
--   fn_open_daily_count() (V59) inserts a row into tbl_daily_cylinder_count
--   but never calls fn_create_checkpoint('DAILY_OPENING', ...).
--
--   As a result, every time the first login of the day fires
--   trg_daily_login_morning_open → fn_daily_login_morning_open()
--   → fn_open_daily_count(), no DAILY_OPENING row is ever written to
--   tbl_reconciliation_checkpoint.
--
--   tbl_reconciliation_checkpoint.checkpoint_type CHECK constraint explicitly
--   lists 'DAILY_OPENING' as a valid type (V61 / V76), but the code path that
--   should create it was never wired.
--
-- FIX (two parts):
--   PART 1 — Replace fn_open_daily_count() so that, on a NEW day, it calls
--             fn_create_checkpoint('DAILY_OPENING', ...) immediately after
--             inserting the tbl_daily_cylinder_count row.
--             Idempotent: if the day is already open the function returns early
--             as before, and no duplicate checkpoint is created.
--
--   PART 2 — Backfill: for every existing tbl_daily_cylinder_count row that
--             has no corresponding DAILY_OPENING checkpoint, insert one now
--             using the opening snapshot values already stored in that row.
-- =============================================================================


-- ===========================================================================
-- PART 1 — Replace fn_open_daily_count()
-- ===========================================================================
-- The ONLY change vs the V59 / V76 version is the three lines at the bottom
-- of the IF block that call fn_create_checkpoint() after the INSERT.
-- All other logic is preserved verbatim so existing callers are unaffected.
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.fn_open_daily_count(
    p_date      date         DEFAULT CURRENT_DATE,
    p_opened_by varchar(200) DEFAULT 'SYSTEM'
)
RETURNS int8 AS $$
DECLARE
    v_existing_id   int8;
    v_new_id        int8;
    v_fleet_total   int4;
    v_yard_full     int4;
    v_yard_empty    int4;
    v_in_transit    int4;
    v_at_customer   int4;
    v_at_supplier   int4;
BEGIN
    -- ── Idempotent guard ─────────────────────────────────────────────────────
    -- If this date is already open, return the existing row ID and stop.
    SELECT pk_daily_count_id INTO v_existing_id
    FROM   public.tbl_daily_cylinder_count
    WHERE  count_date = p_date;

    IF v_existing_id IS NOT NULL THEN
        RETURN v_existing_id;
    END IF;

    -- ── Sample current cylinder status ───────────────────────────────────────
    v_fleet_total := public.fn_current_fleet_count();

    SELECT
        COUNT(*) FILTER (WHERE cs.cylinder_state = 'FULL')             AS yard_full,
        COUNT(*) FILTER (WHERE cs.cylinder_state = 'EMPTY')            AS yard_empty,
        COUNT(*) FILTER (WHERE cs.location = 'In Transit')             AS in_transit,
        COUNT(*) FILTER (WHERE cs.location = 'Customer Location')      AS at_customer,
        COUNT(*) FILTER (WHERE cs.location = 'Supplier Location')      AS at_supplier
    INTO v_yard_full, v_yard_empty, v_in_transit, v_at_customer, v_at_supplier
    FROM public.tbl_cylinder_current_status  ccs
    JOIN public.tbl_cylinder_states          cs
      ON cs.pk_cylinder_state_id = ccs.fk_current_state;

    -- ── Insert the opening snapshot ──────────────────────────────────────────
    INSERT INTO public.tbl_daily_cylinder_count (
        count_date,
        opening_fleet_total,  opening_yard_full,  opening_yard_empty,
        opening_in_transit,   opening_at_customer, opening_at_supplier,
        snapshot_opened_at,   created_by
    ) VALUES (
        p_date,
        v_fleet_total, v_yard_full,    v_yard_empty,
        v_in_transit,  v_at_customer,  v_at_supplier,
        now(),         p_opened_by
    )
    RETURNING pk_daily_count_id INTO v_new_id;

    -- ── FIX: Create the DAILY_OPENING reconciliation checkpoint ─────────────
    -- This was the missing call. fn_create_checkpoint links to the daily count
    -- row that was just inserted (same transaction, so the row is already
    -- visible). expected_count = opening fleet total; threshold = 24 h so the
    -- checkpoint escalates if the day is never closed.
    PERFORM public.fn_create_checkpoint(
        'DAILY_OPENING',                                    -- p_type
        'DAILY_COUNT',                                      -- p_entity_type
        v_new_id,                                           -- p_entity_id
        v_fleet_total,                                      -- p_expected_count
        24,                                                 -- p_threshold_hours
        'Day opened by ' || p_opened_by,                   -- p_remarks
        p_date                                              -- p_checkpoint_date
    );

    RETURN v_new_id;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.fn_open_daily_count(date, varchar) IS
    'Opens a new daily cylinder count snapshot for p_date. '
    'Idempotent — returns the existing row ID when called a second time. '
    'On first call for a given date: samples current cylinder positions, '
    'inserts into tbl_daily_cylinder_count, and creates a DAILY_OPENING '
    'checkpoint in tbl_reconciliation_checkpoint (V77 fix).';


-- ===========================================================================
-- PART 2 — Backfill missing DAILY_OPENING checkpoints for existing data
-- ===========================================================================
-- For every tbl_daily_cylinder_count row that has no matching DAILY_OPENING
-- checkpoint, insert one retroactively using the opening snapshot values
-- already stored. Uses the extended fn_create_checkpoint signature (V76)
-- that accepts p_checkpoint_date so the rows land on the correct date.
-- ===========================================================================

DO $$
DECLARE
    r       public.tbl_daily_cylinder_count%ROWTYPE;
    v_count int := 0;
BEGIN
    FOR r IN
        SELECT dcc.*
        FROM   public.tbl_daily_cylinder_count dcc
        WHERE  NOT EXISTS (
            SELECT 1
            FROM   public.tbl_reconciliation_checkpoint rc
            WHERE  rc.checkpoint_type       = 'DAILY_OPENING'
              AND  rc.reference_entity_type = 'DAILY_COUNT'
              AND  rc.reference_entity_id   = dcc.pk_daily_count_id
        )
        ORDER BY dcc.count_date
    LOOP
        PERFORM public.fn_create_checkpoint(
            'DAILY_OPENING',
            'DAILY_COUNT',
            r.pk_daily_count_id,
            COALESCE(r.opening_fleet_total, 0),
            24,
            'Backfilled by V77 — checkpoint was not created at open time.',
            r.count_date
        );
        v_count := v_count + 1;
    END LOOP;

    RAISE NOTICE 'V77 backfill: inserted % missing DAILY_OPENING checkpoint(s).', v_count;
END;
$$;
