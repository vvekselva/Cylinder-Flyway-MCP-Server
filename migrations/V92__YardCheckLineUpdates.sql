ALTER TABLE public.tbl_yard_stock_check_line RENAME COLUMN observed_state TO observed_cylinder;


ALTER TABLE public.tbl_yard_stock_check_line 
ALTER COLUMN fk_cylinder DROP NOT NULL;
