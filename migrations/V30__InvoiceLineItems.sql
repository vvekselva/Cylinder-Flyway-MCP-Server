CREATE TABLE public.tbl_invoice_line (
    pk_invoice_line_id      int8 NOT NULL,
    fk_invoice              int8 NOT NULL,          -- → tbl_invoice
    fk_order                int8 NOT NULL,          -- → tbl_order (challan)
    fk_order_line           int8 NOT NULL,          -- → tbl_order_line
    fk_cylinder             int8 NOT NULL,          -- → tbl_cylinder
    fk_product              int8 NOT NULL,          -- → tbl_product
    quantity                numeric(10,3) NOT NULL,
    rate_per_uom            numeric(10,2) NOT NULL, -- from tb_customer_product_rates at time of invoice
    taxable_amount          numeric(12,2) NOT NULL, -- quantity × rate_per_uom
    igst_rate               numeric(5,2) NULL,
    cgst_rate               numeric(5,2) NULL,
    sgst_rate               numeric(5,2) NULL,
    igst_amount             numeric(12,2) NULL,
    cgst_amount             numeric(12,2) NULL,
    sgst_amount             numeric(12,2) NULL,
    total_amount            numeric(12,2) NOT NULL,
    CONSTRAINT tbl_invoice_line_pk PRIMARY KEY (pk_invoice_line_id),
    CONSTRAINT tbl_invoice_line_unique UNIQUE (fk_invoice, fk_order_line), -- one line per challan line per invoice
    CONSTRAINT tbl_invoice_line_invoice_fk FOREIGN KEY (fk_invoice)
        REFERENCES public.tbl_invoice(pk_invoice_id),
    CONSTRAINT tbl_invoice_line_order_fk FOREIGN KEY (fk_order)
        REFERENCES public.tbl_order(pk_order_id),
    CONSTRAINT tbl_invoice_line_order_line_fk FOREIGN KEY (fk_order_line)
        REFERENCES public.tbl_order_line(pk_order_line_id),
    CONSTRAINT tbl_invoice_line_cylinder_fk FOREIGN KEY (fk_cylinder)
        REFERENCES public.tbl_cylinder(pk_cylinder_id),
    CONSTRAINT tbl_invoice_line_product_fk FOREIGN KEY (fk_product)
        REFERENCES public.tbl_product(pk_product_id)
);

CREATE SEQUENCE public.pk_invoice_line_id_serial
    INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 START 1 CACHE 1 NO CYCLE;
    