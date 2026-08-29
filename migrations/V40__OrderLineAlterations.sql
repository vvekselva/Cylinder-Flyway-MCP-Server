ALTER TABLE tbl_order_line 
ADD COLUMN is_invoiced bool DEFAULT false NOT NULL,
ADD COLUMN fk_invoice int8 NULL,
ADD COLUMN invoiced_at timestamp NULL;



ALTER TABLE tbl_empty_pickup_line
ADD COLUMN is_invoiced bool DEFAULT false NOT NULL,
ADD COLUMN fk_invoice int8 NULL,
ADD COLUMN invoiced_at timestamp NULL;
