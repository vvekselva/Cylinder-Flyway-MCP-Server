ALTER TABLE public.tbl_cylinder_states ADD ui_display_name varchar(500) NULL;
ALTER TABLE public.tbl_cylinder_states ADD CONSTRAINT tbl_cylinder_states_unique_1 UNIQUE (ui_display_name);



UPDATE public.tbl_cylinder_states SET ui_display_name = 'Comissioned'           WHERE cylinder_state = 'COMISSIONED';
UPDATE public.tbl_cylinder_states SET ui_display_name = 'Empty'              WHERE cylinder_state = 'EMPTY';
UPDATE public.tbl_cylinder_states SET ui_display_name = 'Empty Picked For Refill'        WHERE cylinder_state = 'EMPTY_PICKED_FOR_REFILL';
UPDATE public.tbl_cylinder_states SET ui_display_name = 'Empty Delivered For Refill'        WHERE cylinder_state = 'EMPTY_DELIVERED_FOR_REFILL';
UPDATE public.tbl_cylinder_states SET ui_display_name = 'Full Picked From Supplier'        WHERE cylinder_state = 'FULL_PICKED_FROM_SUPPLIER';
UPDATE public.tbl_cylinder_states SET ui_display_name = 'Full'              WHERE cylinder_state = 'FULL';
UPDATE public.tbl_cylinder_states SET ui_display_name = 'Full Picked Up For Delivery'        WHERE cylinder_state = 'FULL_PICKED_UP_FOR_DELIVERY';
UPDATE public.tbl_cylinder_states SET ui_display_name = 'Delivered For Consumption' WHERE cylinder_state = 'DELIVERED_FOR_CONSUMPTION';
UPDATE public.tbl_cylinder_states SET ui_display_name = 'Empty Picked Up From Supplier'        WHERE cylinder_state = 'EMPTY_PICKED_UP_FROM_SUPPLIER';
UPDATE public.tbl_cylinder_states SET ui_display_name = 'Damaged'        WHERE cylinder_state = 'DAMAGED';
UPDATE public.tbl_cylinder_states SET ui_display_name = 'Lost' WHERE cylinder_state = 'LOST';
UPDATE public.tbl_cylinder_states SET ui_display_name = 'Empty In Transit To Yard' WHERE cylinder_state = 'EMPTY_IN_TRANSIT_TO_YARD';
UPDATE public.tbl_cylinder_states SET ui_display_name = 'Missing' WHERE cylinder_state = 'MISSING';
UPDATE public.tbl_cylinder_states SET ui_display_name = 'Decomissioned' WHERE cylinder_state = 'DECOMISSIONED';
