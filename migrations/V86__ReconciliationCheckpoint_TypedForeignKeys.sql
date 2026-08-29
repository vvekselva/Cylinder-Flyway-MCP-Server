-- =============================================================================
-- V86__ReconciliationCheckpoint_TypedForeignKeys.sql
-- =============================================================================
-- PURPOSE:
--   Replace the generic (reference_entity_type, reference_entity_id) discriminator
--   pattern on tbl_reconciliation_checkpoint with explicit, typed FK columns —
--   one per real business table that a checkpoint can guard.
--
-- MOTIVATION:
--   The JPA entity currently has no typed relationship for the reference entity,
--   forcing callers to cast reference_entity_id depending on reference_entity_type.
--   Adding named FK columns makes every relationship first-class:
--     • JPA @ManyToOne mappings compile-safe and navigable
--     • JOIN queries no longer need the type discriminator filter
--     • Exactly one column is non-NULL per checkpoint row (type invariant)
--
-- NEW COLUMNS:
--   fk_order            → tbl_order            (TRIP_STOP_DELIVERY)
--   fk_empty_pickup     → tbl_empty_pickup      (TRIP_STOP_EMPTY_PICKUP)
--   fk_supplier_trip    → tbl_supplier_trip     (SUPPLIER_DROPOFF, SUPPLIER_COLLECTION)
--   fk_yard_stock_check → tbl_yard_stock_check  (YARD_AUDIT)
--
--   NOTE: fk_vehicle_trip and fk_vehicle_load were already added in V76.
--         fk_daily_count was present from V61.
--
-- EXISTING COLUMNS PRESERVED:
--   reference_entity_type / reference_entity_id are kept for backward
--   compatibility with existing trigger functions (fn_resolve_checkpoint etc.)
--   that filter on them. They can be dropped in a future migration once all
--   trigger functions are updated.
--
-- BACKFILL:
--   Existing rows are backfilled from reference_entity_id where
--   reference_entity_type matches the expected table name.
--
-- FIX (also included here):
--   vw_cylinders_at_suppliers referenced st.trip_date which does not exist on
--   tbl_supplier_trip. The correct column is dropoff_date. The view is
--   recreated with the correct column name.
-- =============================================================================


-- =============================================================================
-- PART 1 — Add typed FK columns
-- =============================================================================

ALTER TABLE public.tbl_reconciliation_checkpoint
    ADD COLUMN IF NOT EXISTS fk_order            int8 NULL,
    ADD COLUMN IF NOT EXISTS fk_empty_pickup     int8 NULL,
    ADD COLUMN IF NOT EXISTS fk_supplier_trip    int8 NULL,
    ADD COLUMN IF NOT EXISTS fk_yard_stock_check int8 NULL;

-- Foreign key constraints
ALTER TABLE public.tbl_reconciliation_checkpoint
    ADD CONSTRAINT tbl_recon_checkpoint_order_fk
        FOREIGN KEY (fk_order)
        REFERENCES public.tbl_order(pk_order_id);

ALTER TABLE public.tbl_reconciliation_checkpoint
    ADD CONSTRAINT tbl_recon_checkpoint_empty_pickup_fk
        FOREIGN KEY (fk_empty_pickup)
        REFERENCES public.tbl_empty_pickup(pk_pickup_id);

ALTER TABLE public.tbl_reconciliation_checkpoint
    ADD CONSTRAINT tbl_recon_checkpoint_supplier_trip_fk
        FOREIGN KEY (fk_supplier_trip)
        REFERENCES public.tbl_supplier_trip(pk_supplier_trip_id);

ALTER TABLE public.tbl_reconciliation_checkpoint
    ADD CONSTRAINT tbl_recon_checkpoint_yard_stock_check_fk
        FOREIGN KEY (fk_yard_stock_check)
        REFERENCES public.tbl_yard_stock_check(pk_stock_check_id);

COMMENT ON COLUMN public.tbl_reconciliation_checkpoint.fk_order IS
    'Typed FK to tbl_order. Non-NULL only for TRIP_STOP_DELIVERY checkpoints. '
    'Mirrors reference_entity_id when reference_entity_type = ''tbl_order''.';

COMMENT ON COLUMN public.tbl_reconciliation_checkpoint.fk_empty_pickup IS
    'Typed FK to tbl_empty_pickup. Non-NULL only for TRIP_STOP_EMPTY_PICKUP checkpoints. '
    'Mirrors reference_entity_id when reference_entity_type = ''tbl_empty_pickup''.';

COMMENT ON COLUMN public.tbl_reconciliation_checkpoint.fk_supplier_trip IS
    'Typed FK to tbl_supplier_trip. Non-NULL for SUPPLIER_DROPOFF and '
    'SUPPLIER_COLLECTION checkpoints. '
    'Mirrors reference_entity_id when reference_entity_type = ''tbl_supplier_trip''.';

COMMENT ON COLUMN public.tbl_reconciliation_checkpoint.fk_yard_stock_check IS
    'Typed FK to tbl_yard_stock_check. Non-NULL only for YARD_AUDIT checkpoints. '
    'Mirrors reference_entity_id when reference_entity_type = ''tbl_yard_stock_check''.';


-- =============================================================================
-- PART 2 — Backfill from existing reference_entity_id values
-- =============================================================================

UPDATE public.tbl_reconciliation_checkpoint
   SET fk_order = reference_entity_id
 WHERE reference_entity_type = 'tbl_order'
   AND reference_entity_id IS NOT NULL
   AND fk_order IS NULL;

UPDATE public.tbl_reconciliation_checkpoint
   SET fk_empty_pickup = reference_entity_id
 WHERE reference_entity_type = 'tbl_empty_pickup'
   AND reference_entity_id IS NOT NULL
   AND fk_empty_pickup IS NULL;

UPDATE public.tbl_reconciliation_checkpoint
   SET fk_supplier_trip = reference_entity_id
 WHERE reference_entity_type = 'tbl_supplier_trip'
   AND reference_entity_id IS NOT NULL
   AND fk_supplier_trip IS NULL;

UPDATE public.tbl_reconciliation_checkpoint
   SET fk_yard_stock_check = reference_entity_id
 WHERE reference_entity_type = 'tbl_yard_stock_check'
   AND reference_entity_id IS NOT NULL
   AND fk_yard_stock_check IS NULL;

-- Also backfill fk_vehicle_trip from reference_entity_id for TRIP_DEPARTURE /
-- TRIP_RETURN rows that were created before V76 added the column directly.
UPDATE public.tbl_reconciliation_checkpoint
   SET fk_vehicle_trip = reference_entity_id
 WHERE reference_entity_type = 'tbl_vehicle_trip'
   AND reference_entity_id IS NOT NULL
   AND fk_vehicle_trip IS NULL;


-- =============================================================================
-- PART 3 — Partial indexes for the new FK columns
-- =============================================================================

CREATE INDEX IF NOT EXISTS idx_recon_checkpoint_order
    ON public.tbl_reconciliation_checkpoint(fk_order)
    WHERE fk_order IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_recon_checkpoint_empty_pickup
    ON public.tbl_reconciliation_checkpoint(fk_empty_pickup)
    WHERE fk_empty_pickup IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_recon_checkpoint_supplier_trip
    ON public.tbl_reconciliation_checkpoint(fk_supplier_trip)
    WHERE fk_supplier_trip IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_recon_checkpoint_yard_stock_check
    ON public.tbl_reconciliation_checkpoint(fk_yard_stock_check)
    WHERE fk_yard_stock_check IS NOT NULL;


-- =============================================================================
-- PART 4 — Fix vw_cylinders_at_suppliers: st.trip_date → st.dropoff_date
--           (tbl_supplier_trip has dropoff_date, not trip_date)
--           This fixes the V83 migration failure.
-- =============================================================================

CREATE OR REPLACE VIEW public.vw_cylinders_at_suppliers AS
SELECT
    s.supplier_name,
    c.cylinder_serial,
    p.product_name,
    cs.cylinder_state                                   AS current_state,
    cpc.entered_at                                      AS dropped_at,
    st.dropoff_date                                     AS dropoff_trip_date,   -- was st.trip_date (wrong)
    EXTRACT(DAY FROM now() - cpc.entered_at)::int       AS days_at_supplier,
    CASE
        WHEN EXTRACT(DAY FROM now() - cpc.entered_at) > 7  THEN 'OVERDUE'
        WHEN EXTRACT(DAY FROM now() - cpc.entered_at) > 3  THEN 'FOLLOW_UP'
        ELSE 'OK'
    END                                                 AS aging_flag
FROM   public.tbl_cylinder_party_custody cpc
JOIN   public.tbl_cylinder               c    ON c.pk_cylinder_id    = cpc.fk_cylinder
JOIN   public.tbl_product                p    ON p.pk_product_id     = c.fk_product
JOIN   public.tbl_supplier               s    ON s.pk_supplier_id    = cpc.fk_supplier
LEFT   JOIN public.tbl_supplier_trip     st   ON st.pk_supplier_trip_id
                                                     = cpc.fk_entry_supplier_trip
LEFT   JOIN public.tbl_cylinder_current_status ccs
           ON ccs.fk_cylinder = cpc.fk_cylinder
LEFT   JOIN public.tbl_cylinder_states   cs
           ON cs.pk_cylinder_state_id = ccs.fk_current_state
WHERE  cpc.custody_status = 'ACTIVE'
  AND  cpc.party_type     = 'SUPPLIER'
ORDER  BY days_at_supplier DESC, s.supplier_name, c.cylinder_serial;

COMMENT ON VIEW public.vw_cylinders_at_suppliers IS
    'Live view: every cylinder currently at a supplier awaiting refill. '
    'aging_flag = OVERDUE (>7 days), FOLLOW_UP (>3 days), OK. '
    'Source of truth: tbl_cylinder_party_custody WHERE custody_status = ACTIVE. '
    'Fixed in V86: dropoff_date replaces the incorrect trip_date reference.';
