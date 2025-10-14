-- Fix get_branch_transaction_report function to match actual return columns
-- This fixes the "structure of query does not match function result type" error

DROP FUNCTION IF EXISTS public.get_branch_transaction_report(uuid, date, date, character varying);

CREATE FUNCTION public.get_branch_transaction_report(
    p_branch_id uuid, 
    p_start_date date, 
    p_end_date date, 
    p_transaction_type character varying DEFAULT NULL::character varying
) 
RETURNS TABLE(
    branch_id uuid, 
    branch_name character varying, 
    total_deposits numeric, 
    total_withdrawals numeric, 
    total_transfers_in numeric,
    total_transfers_out numeric,
    transaction_count bigint
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        b.branch_id,
        b.name as branch_name,
        COALESCE(SUM(CASE WHEN t.type = 'Deposit' THEN t.amount ELSE 0 END), 0) as total_deposits,
        COALESCE(SUM(CASE WHEN t.type = 'Withdrawal' THEN t.amount ELSE 0 END), 0) as total_withdrawals,
        COALESCE(SUM(CASE WHEN t.type = 'BankTransfer-In' THEN t.amount ELSE 0 END), 0) as total_transfers_in,
        COALESCE(SUM(CASE WHEN t.type = 'BankTransfer-Out' THEN t.amount ELSE 0 END), 0) as total_transfers_out,
        COUNT(t.transaction_id) as transaction_count
    FROM branch b
    LEFT JOIN account a ON b.branch_id = a.branch_id
    LEFT JOIN transactions t ON a.acc_id = t.acc_id 
        AND DATE(t.created_at) BETWEEN p_start_date AND p_end_date
        AND (p_transaction_type IS NULL OR t.type = p_transaction_type::transaction_type)
    WHERE b.branch_id = p_branch_id
    GROUP BY b.branch_id, b.name;
END;
$$;
