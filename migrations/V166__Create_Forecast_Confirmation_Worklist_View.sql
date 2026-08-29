-- V166 — Database-backed forecast confirmation worklist
--
-- STALE_CONFIRMATION is already derived by vw_customer_delivery_planning_signal.
-- This dedicated view persists the worklist contract in the database and gives
-- every row an explicit queue order. Stale confirmations are intentionally last.

CREATE OR REPLACE VIEW public.vw_delivery_planning_forecast_confirmation_worklist AS
SELECT
    s.*,
    CASE COALESCE(s.confirmation_status, 'UNCONFIRMED')
        WHEN 'UNCONFIRMED' THEN 1
        WHEN 'CONFIRMED' THEN 2
        WHEN 'STALE_CONFIRMATION' THEN 3
        ELSE 4
    END::INTEGER AS confirmation_queue_order,
    CASE s.forecast_window
        WHEN 'TODAY' THEN 1
        WHEN 'TOMORROW' THEN 2
        WHEN 'THIS_WEEK' THEN 3
        WHEN 'NEXT_WEEK' THEN 4
        ELSE 9
    END::INTEGER AS forecast_window_order
FROM public.vw_customer_delivery_planning_signal s
WHERE s.forecast_window IN ('TODAY', 'TOMORROW', 'THIS_WEEK', 'NEXT_WEEK');

COMMENT ON VIEW public.vw_delivery_planning_forecast_confirmation_worklist IS
'Database-backed delivery-planning confirmation queue. Unconfirmed rows are first, current confirmations next, and stale confirmations last.';
