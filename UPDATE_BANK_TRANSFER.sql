-- UPDATE: Fix transfer function to use 'Bank Transfer' type with proper debit/credit amounts
-- This matches the transaction_type enum in your database

DROP FUNCTION IF EXISTS process_transfer_transaction CASCADE;

CREATE OR REPLACE FUNCTION process_transfer_transaction(
    p_from_acc_id UUID,
    p_to_acc_id UUID,
    p_amount NUMERIC,
    p_description TEXT,
    p_created_by UUID
)
RETURNS TABLE(transaction_id UUID, reference_no BIGINT, from_balance NUMERIC, to_balance NUMERIC, success BOOLEAN, error_message TEXT) AS
$$
DECLARE
    from_current_balance NUMERIC;
    to_current_balance NUMERIC;
    from_updated_balance NUMERIC;
    to_updated_balance NUMERIC;
    new_transaction_id UUID;
    new_reference_no BIGINT;
BEGIN
    -- Start transaction
    BEGIN
        -- Generate new UUID for transaction (this is for the response, actual transactions get their own UUIDs)
        new_transaction_id := gen_random_uuid();
        
        -- Generate unique reference number using sequence
        new_reference_no := nextval('transaction_ref_seq');
        
        -- Get current balances with row locks (order by acc_id to prevent deadlock)
        IF p_from_acc_id < p_to_acc_id THEN
            SELECT balance INTO from_current_balance FROM account WHERE acc_id = p_from_acc_id FOR UPDATE;
            SELECT balance INTO to_current_balance FROM account WHERE acc_id = p_to_acc_id FOR UPDATE;
        ELSE
            SELECT balance INTO to_current_balance FROM account WHERE acc_id = p_to_acc_id FOR UPDATE;
            SELECT balance INTO from_current_balance FROM account WHERE acc_id = p_from_acc_id FOR UPDATE;
        END IF;
        
        -- Check if both accounts exist
        IF from_current_balance IS NULL THEN
            RETURN QUERY SELECT new_transaction_id, new_reference_no, 0::NUMERIC, 0::NUMERIC, FALSE, 'Source account not found'::TEXT;
            RETURN;
        END IF;
        
        IF to_current_balance IS NULL THEN
            RETURN QUERY SELECT new_transaction_id, new_reference_no, 0::NUMERIC, 0::NUMERIC, FALSE, 'Destination account not found'::TEXT;
            RETURN;
        END IF;
        
        -- Check sufficient funds in source account
        IF from_current_balance < p_amount THEN
            RETURN QUERY SELECT new_transaction_id, new_reference_no, from_current_balance, to_current_balance, FALSE, 'Insufficient funds'::TEXT;
            RETURN;
        END IF;
        
        -- Calculate new balances
        from_updated_balance := from_current_balance - p_amount;
        to_updated_balance := to_current_balance + p_amount;
        
        -- Insert bank transfer transaction for source account (debits from source - negative amount)
        INSERT INTO transactions (transaction_id, amount, acc_id, type, description, reference_no, created_at, created_by)
        VALUES (gen_random_uuid(), -p_amount, p_from_acc_id, 'BankTransfer', p_description, new_reference_no, NOW(), p_created_by);
        
        -- Insert bank transfer transaction for destination account (credits to destination - positive amount)
        INSERT INTO transactions (transaction_id, amount, acc_id, type, description, reference_no, created_at, created_by)
        VALUES (gen_random_uuid(), p_amount, p_to_acc_id, 'BankTransfer', p_description, new_reference_no, NOW(), p_created_by);
        
        -- Update account balances
        UPDATE account SET balance = from_updated_balance WHERE acc_id = p_from_acc_id;
        UPDATE account SET balance = to_updated_balance WHERE acc_id = p_to_acc_id;
        
        -- Return success
        RETURN QUERY SELECT new_transaction_id, new_reference_no, from_updated_balance, to_updated_balance, TRUE, 'Transfer successful'::TEXT;
        
    EXCEPTION
        WHEN OTHERS THEN
            -- Rollback happens automatically due to exception
            RETURN QUERY SELECT new_transaction_id, new_reference_no, from_current_balance, to_current_balance, FALSE, SQLERRM::TEXT;
    END;
END;
$$ LANGUAGE plpgsql;

-- Verification query
SELECT 
    proname as function_name,
    pg_get_function_arguments(oid) as arguments
FROM pg_proc 
WHERE proname = 'process_transfer_transaction';

-- Test the function after running (replace with actual UUIDs from your database)
-- SELECT * FROM process_transfer_transaction(
--     'source_account_uuid'::UUID, 
--     'destination_account_uuid'::UUID, 
--     100.00, 
--     'Test transfer', 
--     'user_uuid'::UUID
-- );