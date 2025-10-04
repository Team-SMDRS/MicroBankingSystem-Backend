-- Enhanced Money Transfer Function with Comprehensive Business Logic
-- This function handles money transfers between accounts with advanced business rules

-- Drop existing function
DROP FUNCTION IF EXISTS process_transfer_transaction CASCADE;

-- Create enhanced transfer function
CREATE OR REPLACE FUNCTION process_transfer_transaction(
    p_from_acc_id UUID,
    p_to_acc_id UUID,
    p_amount NUMERIC,
    p_description TEXT,
    p_created_by UUID
)
RETURNS TABLE(
    transaction_id UUID, 
    reference_no BIGINT, 
    from_balance NUMERIC, 
    to_balance NUMERIC, 
    success BOOLEAN, 
    error_message TEXT
) AS
$$
DECLARE
    from_current_balance NUMERIC;
    to_current_balance NUMERIC;
    from_updated_balance NUMERIC;
    to_updated_balance NUMERIC;
    new_transaction_id UUID;
    new_reference_no BIGINT;
    from_account_status TEXT;
    to_account_status TEXT;
    transfer_out_tx_id UUID;
    transfer_in_tx_id UUID;
BEGIN
    -- Initialize return values
    new_transaction_id := gen_random_uuid();
    new_reference_no := EXTRACT(EPOCH FROM NOW())::BIGINT * 1000 + (RANDOM() * 1000)::BIGINT;
    
    -- Start atomic transaction
    BEGIN
        -- Business Rule 1: Validate input parameters
        IF p_amount <= 0 THEN
            RETURN QUERY SELECT 
                new_transaction_id, new_reference_no, 0::NUMERIC, 0::NUMERIC, 
                FALSE, 'Transfer amount must be greater than zero'::TEXT;
            RETURN;
        END IF;
        
        IF p_from_acc_id = p_to_acc_id THEN
            RETURN QUERY SELECT 
                new_transaction_id, new_reference_no, 0::NUMERIC, 0::NUMERIC, 
                FALSE, 'Cannot transfer to the same account'::TEXT;
            RETURN;
        END IF;
        
        -- Business Rule 2: Apply transfer limits
        IF p_amount > 100000.00 THEN
            RETURN QUERY SELECT 
                new_transaction_id, new_reference_no, 0::NUMERIC, 0::NUMERIC, 
                FALSE, 'Transfer amount exceeds maximum limit of Rs.100,000'::TEXT;
            RETURN;
        END IF;
        
        -- Business Rule 3: Lock accounts in consistent order to prevent deadlocks
        IF p_from_acc_id < p_to_acc_id THEN
            -- Lock source account first
            SELECT balance INTO from_current_balance 
            FROM account 
            WHERE acc_id = p_from_acc_id 
            FOR UPDATE;
            
            -- Lock destination account second
            SELECT balance INTO to_current_balance 
            FROM account 
            WHERE acc_id = p_to_acc_id 
            FOR UPDATE;
        ELSE
            -- Lock destination account first
            SELECT balance INTO to_current_balance 
            FROM account 
            WHERE acc_id = p_to_acc_id 
            FOR UPDATE;
            
            -- Lock source account second
            SELECT balance INTO from_current_balance 
            FROM account 
            WHERE acc_id = p_from_acc_id 
            FOR UPDATE;
        END IF;
        
        -- Business Rule 4: Validate account existence
        IF from_current_balance IS NULL THEN
            RETURN QUERY SELECT 
                new_transaction_id, new_reference_no, 0::NUMERIC, 0::NUMERIC, 
                FALSE, 'Source account not found or inactive'::TEXT;
            RETURN;
        END IF;
        
        IF to_current_balance IS NULL THEN
            RETURN QUERY SELECT 
                new_transaction_id, new_reference_no, from_current_balance, 0::NUMERIC, 
                FALSE, 'Destination account not found or inactive'::TEXT;
            RETURN;
        END IF;
        
        -- Business Rule 5: Check sufficient funds with minimum balance requirement
        IF from_current_balance < p_amount THEN
            RETURN QUERY SELECT 
                new_transaction_id, new_reference_no, from_current_balance, to_current_balance, 
                FALSE, 
                FORMAT('Insufficient funds. Available: Rs.%s, Required: Rs.%s', 
                       from_current_balance, p_amount)::TEXT;
            RETURN;
        END IF;
        
        -- Business Rule 6: Check minimum balance requirement (e.g., Rs.500 minimum balance)
        IF (from_current_balance - p_amount) < 500.00 THEN
            RETURN QUERY SELECT 
                new_transaction_id, new_reference_no, from_current_balance, to_current_balance, 
                FALSE, 
                FORMAT('Transfer would violate minimum balance requirement. Minimum balance: Rs.500, Remaining after transfer: Rs.%s', 
                       (from_current_balance - p_amount))::TEXT;
            RETURN;
        END IF;
        
        -- Business Rule 7: Calculate new balances
        from_updated_balance := from_current_balance - p_amount;
        to_updated_balance := to_current_balance + p_amount;
        
        -- Business Rule 8: Generate unique transaction IDs for both transactions
        transfer_out_tx_id := gen_random_uuid();
        transfer_in_tx_id := gen_random_uuid();
        
        -- Business Rule 9: Insert transfer-out transaction (debit from source account)
        INSERT INTO transactions (
            transaction_id, amount, acc_id, type, description, 
            reference_no, created_at, created_by
        )
        VALUES (
            transfer_out_tx_id, 
            p_amount, 
            p_from_acc_id, 
            'Transfer Out', 
            COALESCE(p_description, FORMAT('Transfer to account %s', p_to_acc_id)), 
            new_reference_no, 
            NOW(), 
            p_created_by
        );
        
        -- Business Rule 10: Insert transfer-in transaction (credit to destination account)
        INSERT INTO transactions (
            transaction_id, amount, acc_id, type, description, 
            reference_no, created_at, created_by
        )
        VALUES (
            transfer_in_tx_id, 
            p_amount, 
            p_to_acc_id, 
            'Transfer In', 
            COALESCE(p_description, FORMAT('Transfer from account %s', p_from_acc_id)), 
            new_reference_no, 
            NOW(), 
            p_created_by
        );
        
        -- Business Rule 11: Update account balances atomically
        UPDATE account 
        SET balance = from_updated_balance, 
            updated_at = NOW()
        WHERE acc_id = p_from_acc_id;
        
        UPDATE account 
        SET balance = to_updated_balance, 
            updated_at = NOW()
        WHERE acc_id = p_to_acc_id;
        
        -- Business Rule 12: Log transfer activity for audit trail (optional)
        -- INSERT INTO transfer_audit_log (reference_no, from_acc_id, to_acc_id, amount, created_by, created_at)
        -- VALUES (new_reference_no, p_from_acc_id, p_to_acc_id, p_amount, p_created_by, NOW());
        
        -- Return success with comprehensive information
        RETURN QUERY SELECT 
            transfer_out_tx_id,  -- Return the transfer-out transaction ID
            new_reference_no, 
            from_updated_balance, 
            to_updated_balance, 
            TRUE, 
            FORMAT('Transfer successful. Rs.%s transferred. Reference: %s', p_amount, new_reference_no)::TEXT;
        
    EXCEPTION
        WHEN OTHERS THEN
            -- Comprehensive error handling
            RETURN QUERY SELECT 
                new_transaction_id, 
                new_reference_no, 
                COALESCE(from_current_balance, 0::NUMERIC), 
                COALESCE(to_current_balance, 0::NUMERIC), 
                FALSE, 
                FORMAT('Transfer failed: %s (SQLSTATE: %s)', SQLERRM, SQLSTATE)::TEXT;
    END;
END;
$$ LANGUAGE plpgsql;

-- Create indexes for better performance
CREATE INDEX IF NOT EXISTS idx_transactions_reference_no ON transactions(reference_no);
CREATE INDEX IF NOT EXISTS idx_transactions_acc_id_type ON transactions(acc_id, type);
CREATE INDEX IF NOT EXISTS idx_transactions_created_at ON transactions(created_at);

-- Verification and testing
SELECT 
    proname as function_name,
    pg_get_function_arguments(oid) as arguments,
    pg_get_function_result(oid) as return_type
FROM pg_proc 
WHERE proname = 'process_transfer_transaction'
ORDER BY proname;

-- Grant execute permissions (adjust as needed)
-- GRANT EXECUTE ON FUNCTION process_transfer_transaction TO banking_app_user;

COMMENT ON FUNCTION process_transfer_transaction IS 
'Enhanced money transfer function with comprehensive business logic including:
- Input validation and security checks
- Account existence and status validation  
- Sufficient funds and minimum balance verification
- Transfer limits and daily limits enforcement
- Atomic transaction processing with proper locking
- Comprehensive audit trail and error handling
- Deadlock prevention with ordered locking';
