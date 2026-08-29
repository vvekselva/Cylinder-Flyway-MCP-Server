-- =============================================================================
-- V140__Fix_Daily_Login_Daily_Count_Idempotency.sql
-- =============================================================================
-- PURPOSE
--   Fix login failure caused by duplicate daily count opening when multiple login
--   inserts happen for the same business date.
--
-- ROOT CAUSE
--   fn_open_daily_count() used SELECT-then-INSERT. Under concurrent login inserts,
--   two transactions can both see no row for CURRENT_DATE and both try to insert
--   tbl_daily_cylinder_count(count_date = CURRENT_DATE). The second transaction
--   violates tbl_daily_cylinder_count_date_unique.
--
-- FIX
--   1. Make fn_open_daily_count() concurrency-safe using INSERT ... ON CONFLICT.
--   2. Serialize fn_daily_login_morning_open() per business date using an advisory
--      transaction lock before checking first-login/carry-forward behavior.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_open_daily_count(
    p_date       date         DEFAULT CURRENT_DATE,
    p_opened_by  varchar(200) DEFAULT 'SYSTEM'
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
    -- Fast path: return existing row when already opened.
    SELECT pk_daily_count_id
      INTO v_existing_id
      FROM public.tbl_daily_cylinder_count
     WHERE count_date = p_date;

    IF v_existing_id IS NOT NULL THEN
        RETURN v_existing_id;
    END IF;

    -- Sample current snapshot only when an insert might be needed.
    v_fleet_total := public.fn_current_fleet_count();

    SELECT
        COUNT(*) FILTER (WHERE cs.cylinder_state = 'FULL') AS yard_full,
        COUNT(*) FILTER (WHERE cs.cylinder_state = 'EMPTY') AS yard_empty,
        COUNT(*) FILTER (WHERE cs.location = 'In Transit') AS in_transit,
        COUNT(*) FILTER (WHERE cs.location = 'Customer Location') AS at_customer,
        COUNT(*) FILTER (WHERE cs.location = 'Supplier Location') AS at_supplier
    INTO v_yard_full, v_yard_empty, v_in_transit, v_at_customer, v_at_supplier
    FROM public.tbl_cylinder_current_status ccs
    JOIN public.tbl_cylinder_states cs
      ON cs.pk_cylinder_state_id = ccs.fk_current_state;

    -- Concurrency-safe insert. If another login opened the same date first,
    -- do nothing and return the existing row below.
    INSERT INTO public.tbl_daily_cylinder_count (
        count_date,
        opening_fleet_total, opening_yard_full, opening_yard_empty,
        opening_in_transit, opening_at_customer, opening_at_supplier,
        snapshot_opened_at, created_by
    ) VALUES (
        p_date,
        COALESCE(v_fleet_total, 0), COALESCE(v_yard_full, 0), COALESCE(v_yard_empty, 0),
        COALESCE(v_in_transit, 0), COALESCE(v_at_customer, 0), COALESCE(v_at_supplier, 0),
        now(), p_opened_by
    )
    ON CONFLICT (count_date) DO NOTHING
    RETURNING pk_daily_count_id INTO v_new_id;

    IF v_new_id IS NOT NULL THEN
        RETURN v_new_id;
    END IF;

    SELECT pk_daily_count_id
      INTO v_existing_id
      FROM public.tbl_daily_cylinder_count
     WHERE count_date = p_date;

    IF v_existing_id IS NULL THEN
        RAISE EXCEPTION 'Unable to open or fetch daily cylinder count for date %', p_date;
    END IF;

    RETURN v_existing_id;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.fn_open_daily_count(date, varchar) IS
    'V140 — concurrency-safe/idempotent daily count opener. Uses ON CONFLICT on count_date.';


CREATE OR REPLACE FUNCTION public.fn_daily_login_morning_open()
RETURNS TRIGGER AS $$
DECLARE
    v_today          date := CURRENT_DATE;
    v_yesterday      date := CURRENT_DATE - 1;
    v_is_first_login boolean;
    v_yesterday_row  public.tbl_last_login%ROWTYPE;
BEGIN
    -- Serialize the first-login decision for the date. This prevents parallel
    -- login inserts from both treating themselves as the first login of the day.
    PERFORM pg_advisory_xact_lock(hashtext('DAILY_LOGIN_MORNING_OPEN:' || v_today::text));

    SELECT NOT EXISTS (
        SELECT 1
          FROM public.tbl_last_login
         WHERE login_date = v_today
    ) INTO v_is_first_login;

    IF v_is_first_login THEN
        SELECT * INTO v_yesterday_row
          FROM public.tbl_last_login
         WHERE login_date = v_yesterday;

        IF FOUND AND v_yesterday_row.eod_reconciled = false THEN
            PERFORM public.fn_carry_forward_unreconciled_day(v_yesterday);
        END IF;

        PERFORM public.fn_open_daily_count(v_today, 'MORNING_LOGIN');
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.fn_daily_login_morning_open() IS
    'V140 — serializes first-login daily open with advisory lock and relies on idempotent fn_open_daily_count.';
