-- Migration: Update fixed_deposit_details view to include status and next_interest_day columns
-- This fixes the validation error for missing fields in FixedDepositResponse

DROP VIEW IF EXISTS public.fixed_deposit_details CASCADE;

CREATE VIEW public.fixed_deposit_details AS
 SELECT fd.fd_id,
    fd.fd_account_no,
    fd.balance,
    fd.acc_id,
    fd.opened_date,
    fd.maturity_date,
    fd.fd_plan_id,
    fd.created_at AS fd_created_at,
    fd.updated_at AS fd_updated_at,
    fd.status,
    fd.next_interest_day,
    a.account_no,
    b.name AS branch_name,
    fp.duration AS plan_duration,
    fp.interest_rate AS plan_interest_rate
   FROM (((public.fixed_deposit fd
     LEFT JOIN public.account a ON ((fd.acc_id = a.acc_id)))
     LEFT JOIN public.branch b ON ((a.branch_id = b.branch_id)))
     LEFT JOIN public.fd_plan fp ON ((fd.fd_plan_id = fp.fd_plan_id)));
