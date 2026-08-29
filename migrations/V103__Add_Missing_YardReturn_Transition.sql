-- =============================================================================
-- V103: Add missing state transition EMPTY_PICKED_FOR_REFILL → EMPTY
-- =============================================================================
-- Root cause:
--   CompleteTrip creates yard entries for all cylinders still on the vehicle.
--   fn_audit_cylinder_yard_entry_after() transitions them all to EMPTY.
--   Cylinders in EMPTY_PICKED_FOR_REFILL (loaded for supplier but never
--   delivered) are also on the vehicle, so the trigger hits them too.
--   V98 built tbl_cylinder_state_transition without this path, causing
--   fn_cylinder_state_machine() to RAISE on commit.
-- =============================================================================

INSERT INTO public.tbl_cylinder_state_transition (from_state, to_state, description)
VALUES (
    'EMPTY_PICKED_FOR_REFILL',
    'EMPTY',
    'Supplier trip aborted / cylinders returned to yard before supplier delivery'
)
ON CONFLICT (from_state, to_state) DO NOTHING;