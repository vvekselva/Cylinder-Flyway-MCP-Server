-- =============================================================================
-- V54__VehicleLoad_AggregateDistribution.sql
-- =============================================================================
-- PROBLEM
-- -------
-- tbl_vehicle_load_line.fk_load_purpose is NOT NULL (added in V42).
-- The UI never collected a per-line purpose → service sent NULL →
-- fn_check_cylinder_before_vehicle_load() raised:
--   "ERROR: Unknown fk_load_purpose: <NULL>"
--
-- ROOT CAUSE
-- ----------
-- Assigning purpose per cylinder at scan time is operationally impractical.
-- Staff load 50–90 cylinders and cannot tag each one individually.
-- The intent (delivery vs buffer vs refill) is only known as an AGGREGATE
-- at the end of the loading session.
--
-- SOLUTION
-- --------
-- 1. Add FULL_FOR_BUFFER to tbl_vehicle_load_purpose.
--    (FULL_FOR_DELIVERY and EMPTY_FOR_SUPPLIER already exist from V42.)
--
-- 2. Update both trigger functions to handle the new purpose.
--
-- 3. Add three qty columns to tbl_vehicle_load (header level):
--      qty_full_for_delivery  INTEGER NOT NULL DEFAULT 0
--      qty_full_for_buffer    INTEGER NOT NULL DEFAULT 0
--      qty_empty_for_supplier INTEGER NOT NULL DEFAULT 0
--
--    The service reads these and assigns fk_load_purpose per line before saving:
--      · Sort FULL lines in insertion order.
--      · Assign FULL_FOR_DELIVERY to the first qty_full_for_delivery lines.
--      · Assign FULL_FOR_BUFFER   to the remaining FULL lines.
--      · Assign EMPTY_FOR_SUPPLIER to every EMPTY line.
--
-- VIEW BINDING (Uc02-Phase01-VehicleLoadView.html)
-- -------------------------------------------------
--   vehicleLoadDto.qtyFullForDelivery  → qty_full_for_delivery
--   vehicleLoadDto.qtyFullForBuffer    → qty_full_for_buffer
--   vehicleLoadDto.qtyEmptyForSupplier → qty_empty_for_supplier
--
-- SERVICE (VehicleLoadIngestionService.processRequest)
-- ----------------------------------------------------
--   After calling VehicleLoadMapper.mapDtoToDo():
--     List<VehicleLoadLineDo> fullLines  = lines where cylinder.state == FULL
--     List<VehicleLoadLineDo> emptyLines = lines where cylinder.state == EMPTY
--
--     Long deliveryPurposeId = loadPurposeRepo.findByLoadPurpose("FULL_FOR_DELIVERY").getId();
--     Long bufferPurposeId   = loadPurposeRepo.findByLoadPurpose("FULL_FOR_BUFFER").getId();
--     Long supplierPurposeId = loadPurposeRepo.findByLoadPurpose("EMPTY_FOR_SUPPLIER").getId();
--
--     int deliveryCount = vehicleLoadDo.getQtyFullForDelivery();
--     for (int i = 0; i < fullLines.size(); i++) {
--         fullLines.get(i).setLoadPurpose(
--             i < deliveryCount ? deliveryPurposeId : bufferPurposeId
--         );
--     }
--     emptyLines.forEach(l -> l.setLoadPurpose(supplierPurposeId));
--
--   Then persist vehicleLoadDo (cascades to lines).
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- PART 1  Add FULL_FOR_BUFFER to the purpose lookup
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO public.tbl_vehicle_load_purpose
    (pk_load_purpose_id, load_purpose, description)
VALUES (
    nextval('public.pk_load_purpose_id_serial'),
    'FULL_FOR_BUFFER',
    'Full cylinder loaded onto vehicle as buffer / adhoc supply — not pre-assigned to a customer delivery stop'
);


-- ─────────────────────────────────────────────────────────────────────────────
-- PART 2  Update BEFORE-INSERT trigger to handle FULL_FOR_BUFFER
--         Required state: FULL  (same as FULL_FOR_DELIVERY)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.fn_check_cylinder_before_vehicle_load()
RETURNS TRIGGER AS $$
DECLARE
    v_purpose_name        varchar(100);
    v_required_state_name varchar(100);
    v_required_state_id   int8;
    v_current_state_id    int8;
BEGIN
    SELECT load_purpose
      INTO v_purpose_name
      FROM public.tbl_vehicle_load_purpose
     WHERE pk_load_purpose_id = NEW.fk_load_purpose;

    IF v_purpose_name IS NULL THEN
        RAISE EXCEPTION 'Unknown fk_load_purpose: %', NEW.fk_load_purpose;
    END IF;

    v_required_state_name :=
        CASE v_purpose_name
            WHEN 'FULL_FOR_DELIVERY'       THEN 'FULL'
            WHEN 'FULL_FOR_BUFFER'         THEN 'FULL'   -- same required state
            WHEN 'EMPTY_FOR_SUPPLIER'      THEN 'EMPTY'
            WHEN 'EMPTY_RETURNED_TO_YARD'  THEN 'DELIVERED_FOR_CONSUMPTION'
            ELSE NULL
        END;

    IF v_required_state_name IS NULL THEN
        RAISE EXCEPTION
            'No required state mapping defined for load purpose "%". '
            'Add a WHEN branch in fn_check_cylinder_before_vehicle_load.',
            v_purpose_name;
    END IF;

    SELECT pk_cylinder_state_id
      INTO v_required_state_id
      FROM public.tbl_cylinder_states
     WHERE cylinder_state = v_required_state_name;

    -- Fast path: current-status table
    SELECT fk_current_state
      INTO v_current_state_id
      FROM public.tbl_cylinder_current_status
     WHERE fk_cylinder = NEW.fk_cylinder;

    -- Fallback: audit log
    IF v_current_state_id IS NULL THEN
        SELECT fk_new_state
          INTO v_current_state_id
          FROM public.tbl_cylinder_state_audit
         WHERE fk_cylinder = NEW.fk_cylinder
         ORDER BY changed_at DESC, pk_audit_id DESC
         LIMIT 1;
    END IF;

    IF v_current_state_id IS DISTINCT FROM v_required_state_id THEN
        RAISE EXCEPTION
            'Validation Failed: Cylinder % must be in state "%" for load purpose "%".',
            NEW.fk_cylinder,
            v_required_state_name,
            v_purpose_name;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- ─────────────────────────────────────────────────────────────────────────────
-- PART 3  Update AFTER-INSERT trigger to handle FULL_FOR_BUFFER
--         State transition: FULL → FULL_PICKED_UP_FOR_DELIVERY
--         (Buffer cylinders are physically on the same vehicle as delivery
--          cylinders — the distinction is business-level only.)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.fn_audit_cylinder_load_after()
RETURNS TRIGGER AS $$
DECLARE
    v_purpose_name  varchar(100);
    v_prev_state    varchar(100);
    v_new_state     varchar(100);
    v_prev_state_id int8;
    v_new_state_id  int8;
BEGIN
    SELECT load_purpose
      INTO v_purpose_name
      FROM public.tbl_vehicle_load_purpose
     WHERE pk_load_purpose_id = NEW.fk_load_purpose;

    CASE v_purpose_name
        WHEN 'FULL_FOR_DELIVERY' THEN
            v_prev_state := 'FULL';
            v_new_state  := 'FULL_PICKED_UP_FOR_DELIVERY';

        WHEN 'FULL_FOR_BUFFER' THEN
            v_prev_state := 'FULL';
            v_new_state  := 'FULL_PICKED_UP_FOR_DELIVERY';  -- same physical transition

        WHEN 'EMPTY_FOR_SUPPLIER' THEN
            v_prev_state := 'EMPTY';
            v_new_state  := 'EMPTY_PICKED_FOR_REFILL';

        WHEN 'EMPTY_RETURNED_TO_YARD' THEN
            v_prev_state := 'DELIVERED_FOR_CONSUMPTION';
            v_new_state  := 'EMPTY_IN_TRANSIT_TO_YARD';

        ELSE
            RAISE EXCEPTION
                'No state transition defined for load purpose "%". '
                'Add a WHEN branch in fn_audit_cylinder_load_after.',
                v_purpose_name;
    END CASE;

    SELECT pk_cylinder_state_id INTO v_prev_state_id
      FROM public.tbl_cylinder_states WHERE cylinder_state = v_prev_state;

    SELECT pk_cylinder_state_id INTO v_new_state_id
      FROM public.tbl_cylinder_states WHERE cylinder_state = v_new_state;

    INSERT INTO public.tbl_cylinder_state_audit (
        pk_audit_id, fk_cylinder, fk_previous_state, fk_new_state,
        fk_order, changed_at, remarks
    ) VALUES (
        nextval('public.pk_cylinder_state_id_serial'),
        NEW.fk_cylinder,
        v_prev_state_id,
        v_new_state_id,
        NULL,
        now(),
        'Vehicle load line inserted — purpose: ' || v_purpose_name
    );

    UPDATE public.tbl_cylinder_current_status
       SET fk_current_vehicle_load = NEW.fk_vehicle_load,
           updated_at              = now()
     WHERE fk_cylinder = NEW.fk_cylinder;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- ─────────────────────────────────────────────────────────────────────────────
-- PART 4  Aggregate distribution columns on tbl_vehicle_load
--         These are the header-level quantities the UI collects and the
--         service uses to assign per-line purposes.
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.tbl_vehicle_load
    ADD COLUMN IF NOT EXISTS qty_full_for_delivery  INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS qty_full_for_buffer    INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS qty_empty_for_supplier INTEGER NOT NULL DEFAULT 0;

COMMENT ON COLUMN public.tbl_vehicle_load.qty_full_for_delivery  IS
    'Number of FULL cylinders loaded for customer delivery (FULL_FOR_DELIVERY purpose)';
COMMENT ON COLUMN public.tbl_vehicle_load.qty_full_for_buffer    IS
    'Number of FULL cylinders loaded as buffer/adhoc supply (FULL_FOR_BUFFER purpose)';
COMMENT ON COLUMN public.tbl_vehicle_load.qty_empty_for_supplier IS
    'Number of EMPTY cylinders loaded for supplier refill (EMPTY_FOR_SUPPLIER purpose)';


-- =============================================================================
-- ENTITY / DTO CHANGES REQUIRED IN JAVA
-- =============================================================================
--
-- VehicleLoadDo (entity for tbl_vehicle_load):
--   @Column(name = "qty_full_for_delivery")  private int qtyFullForDelivery;
--   @Column(name = "qty_full_for_buffer")    private int qtyFullForBuffer;
--   @Column(name = "qty_empty_for_supplier") private int qtyEmptyForSupplier;
--
-- VehicleLoadDto (request DTO bound from the form):
--   private int qtyFullForDelivery;   // vehicleLoadDto.qtyFullForDelivery
--   private int qtyFullForBuffer;     // vehicleLoadDto.qtyFullForBuffer
--   private int qtyEmptyForSupplier;  // vehicleLoadDto.qtyEmptyForSupplier
--
-- VehicleLoadMapper.mapDtoToDo():
--   do.setQtyFullForDelivery(dto.getQtyFullForDelivery());
--   do.setQtyFullForBuffer(dto.getQtyFullForBuffer());
--   do.setQtyEmptyForSupplier(dto.getQtyEmptyForSupplier());
--
-- VehicleLoadIngestionService.processRequest() — CRITICAL CHANGE:
--   After mapping header DTO → DO, resolve purposes and assign per line:
--
--   VehicleLoadPurposeDo deliveryPurpose =
--       loadPurposeRepository.findByLoadPurpose("FULL_FOR_DELIVERY").orElseThrow();
--   VehicleLoadPurposeDo bufferPurpose =
--       loadPurposeRepository.findByLoadPurpose("FULL_FOR_BUFFER").orElseThrow();
--   VehicleLoadPurposeDo supplierPurpose =
--       loadPurposeRepository.findByLoadPurpose("EMPTY_FOR_SUPPLIER").orElseThrow();
--
--   List<VehicleLoadLineDo> fullLines = mappedLines.stream()
--       .filter(l -> "FULL".equals(l.getCylinder().getCurrentState()))
--       .collect(Collectors.toList());
--   List<VehicleLoadLineDo> emptyLines = mappedLines.stream()
--       .filter(l -> "EMPTY".equals(l.getCylinder().getCurrentState()))
--       .collect(Collectors.toList());
--
--   int deliveryCount = vehicleLoadDo.getQtyFullForDelivery();
--   for (int i = 0; i < fullLines.size(); i++) {
--       fullLines.get(i).setLoadPurpose(
--           i < deliveryCount ? deliveryPurpose : bufferPurpose
--       );
--   }
--   emptyLines.forEach(l -> l.setLoadPurpose(supplierPurpose));
--
-- =============================================================================
ALTER TABLE public.tbl_vehicle_load RENAME COLUMN qty_full_for_delivery TO "quantity_full_for_delivery";
ALTER TABLE public.tbl_vehicle_load RENAME COLUMN qty_full_for_buffer TO "quantity_full_for_buffer";
ALTER TABLE public.tbl_vehicle_load RENAME COLUMN qty_empty_for_supplier TO "quantity_empty_for_supplier";
