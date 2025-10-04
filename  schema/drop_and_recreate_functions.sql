-- Drop ALL existing versions of these functions regardless of parameter types
DO $$
DECLARE
    func_name TEXT;
    func_names TEXT[] := ARRAY[
        'get_transaction_history_by_account',
        'get_transaction_history_by_date_range', 
        'get_branch_transaction_report',
        'calculate_transaction_totals',
        'get_all_transactions_with_account_details'
    ];
BEGIN
    FOREACH func_name IN ARRAY func_names
    LOOP
        -- Drop all overloaded versions of each function
        EXECUTE format('DROP FUNCTION IF EXISTS %I CASCADE', func_name);
    END LOOP;
END $$;

-- Also drop specific known versions
DROP FUNCTION IF EXISTS get_transaction_history_by_account(character varying, integer, integer);
DROP FUNCTION IF EXISTS get_transaction_history_by_date_range(date, date, character varying, character varying);
DROP FUNCTION IF EXISTS get_branch_transaction_report(character varying, date, date, character varying);
DROP FUNCTION IF EXISTS calculate_transaction_totals(character varying, character varying, date, date);
DROP FUNCTION IF EXISTS get_all_transactions_with_account_details(integer, integer);

-- Drop existing UUID versions (if they exist)
DROP FUNCTION IF EXISTS get_transaction_history_by_account(uuid, integer, integer);
DROP FUNCTION IF EXISTS get_transaction_history_by_date_range(date, date, uuid, character varying);
DROP FUNCTION IF EXISTS get_branch_transaction_report(uuid, date, date, character varying);
DROP FUNCTION IF EXISTS calculate_transaction_totals(uuid, character varying, date, date);
DROP FUNCTION IF EXISTS get_all_transactions_with_account_details(integer, integer);

-- Now recreate all functions with correct UUID types

-- Function to process deposit transactions with auto-generation and rollback
CREATE OR REPLACE FUNCTION process_deposit_transaction(
    p_acc_id UUID,
    p_amount NUMERIC,
    p_description TEXT,
    p_created_by UUID
)
RETURNS TABLE(transaction_id UUID, reference_no BIGINT, new_balance NUMERIC, success BOOLEAN, error_message TEXT) AS
$$
DECLARE
    current_balance NUMERIC;
    updated_balance NUMERIC;
    new_transaction_id UUID;
    new_reference_no BIGINT;
BEGIN
    -- Start transaction
    BEGIN
        -- Generate new UUID for transaction
        new_transaction_id := gen_random_uuid();
        
        -- Generate new reference number (using epoch seconds + random number)
        new_reference_no := EXTRACT(EPOCH FROM NOW())::BIGINT * 1000 + (RANDOM() * 1000)::BIGINT;
        
        -- Get current balance with row lock
        SELECT balance INTO current_balance FROM account WHERE acc_id = p_acc_id FOR UPDATE;
        
        IF current_balance IS NULL THEN
            RETURN QUERY SELECT new_transaction_id, new_reference_no, 0::NUMERIC, FALSE, 'Account not found'::TEXT;
            RETURN;
        END IF;
        
        -- Calculate new balance
        updated_balance := current_balance + p_amount;
        
        -- Insert transaction record
        INSERT INTO transactions (transaction_id, amount, acc_id, type, description, reference_no, created_at, created_by)
        VALUES (new_transaction_id, p_amount, p_acc_id, 'Deposit', p_description, new_reference_no, NOW(), p_created_by);
        
        -- Update account balance
        UPDATE account SET balance = updated_balance WHERE acc_id = p_acc_id;
        
        -- Return success
        RETURN QUERY SELECT new_transaction_id, new_reference_no, updated_balance, TRUE, 'Deposit successful'::TEXT;
        
    EXCEPTION
        WHEN OTHERS THEN
            -- Rollback happens automatically due to exception
            RETURN QUERY SELECT new_transaction_id, new_reference_no, current_balance, FALSE, SQLERRM::TEXT;
    END;
END;
$$ LANGUAGE plpgsql;

-- Function to process withdrawal transactions with auto-generation and rollback
CREATE OR REPLACE FUNCTION process_withdrawal_transaction(
    p_acc_id UUID,
    p_amount NUMERIC,
    p_description TEXT,
    p_created_by UUID
)
RETURNS TABLE(transaction_id UUID, reference_no BIGINT, new_balance NUMERIC, success BOOLEAN, error_message TEXT) AS
$$
DECLARE
    current_balance NUMERIC;
    updated_balance NUMERIC;
    new_transaction_id UUID;
    new_reference_no BIGINT;
BEGIN
    -- Start transaction
    BEGIN
        -- Generate new UUID for transaction
        new_transaction_id := gen_random_uuid();
        
        -- Generate new reference number (using epoch seconds + random number)
        new_reference_no := EXTRACT(EPOCH FROM NOW())::BIGINT * 1000 + (RANDOM() * 1000)::BIGINT;
        
        -- Get current balance with row lock
        SELECT balance INTO current_balance FROM account WHERE acc_id = p_acc_id FOR UPDATE;
        
        IF current_balance IS NULL THEN
            RETURN QUERY SELECT new_transaction_id, new_reference_no, 0::NUMERIC, FALSE, 'Account not found'::TEXT;
            RETURN;
        END IF;
        
        -- Check sufficient funds
        IF current_balance < p_amount THEN
            RETURN QUERY SELECT new_transaction_id, new_reference_no, current_balance, FALSE, 'Insufficient funds'::TEXT;
            RETURN;
        END IF;
        
        -- Calculate new balance
        updated_balance := current_balance - p_amount;
        
        -- Insert transaction record
        INSERT INTO transactions (transaction_id, amount, acc_id, type, description, reference_no, created_at, created_by)
        VALUES (new_transaction_id, p_amount, p_acc_id, 'Withdrawal', p_description, new_reference_no, NOW(), p_created_by);
        
        -- Update account balance
        UPDATE account SET balance = updated_balance WHERE acc_id = p_acc_id;
        
        -- Return success
        RETURN QUERY SELECT new_transaction_id, new_reference_no, updated_balance, TRUE, 'Withdrawal successful'::TEXT;
        
    EXCEPTION
        WHEN OTHERS THEN
            -- Rollback happens automatically due to exception
            RETURN QUERY SELECT new_transaction_id, new_reference_no, current_balance, FALSE, SQLERRM::TEXT;
    END;
END;
$$ LANGUAGE plpgsql;

-- Function to get transaction history by account (NEW with UUID types)
CREATE FUNCTION get_transaction_history_by_account(
    p_acc_id UUID,
    p_limit INTEGER,
    p_offset INTEGER
)
RETURNS TABLE(
    transaction_id UUID,
    amount NUMERIC,
    acc_id UUID,
    type transaction_type,
    description TEXT,
    reference_no BIGINT,
    created_at TIMESTAMP,
    created_by UUID
) AS
$$
BEGIN
    RETURN QUERY
    SELECT t.transaction_id, t.amount, t.acc_id, t.type, t.description, t.reference_no, t.created_at, t.created_by
    FROM transactions t
    WHERE t.acc_id = p_acc_id
    ORDER BY t.created_at DESC
    LIMIT p_limit OFFSET p_offset;
END;
$$ LANGUAGE plpgsql;

-- Function to get transaction history by date range (NEW with UUID types)
CREATE FUNCTION get_transaction_history_by_date_range(
    p_start_date DATE,
    p_end_date DATE,
    p_acc_id UUID DEFAULT NULL,
    p_transaction_type VARCHAR DEFAULT NULL
)
RETURNS TABLE(
    transaction_id UUID,
    amount NUMERIC,
    acc_id UUID,
    type transaction_type,
    description TEXT,
    reference_no BIGINT,
    created_at TIMESTAMP,
    created_by UUID
) AS
$$
BEGIN
    RETURN QUERY
    SELECT t.transaction_id, t.amount, t.acc_id, t.type, t.description, t.reference_no, t.created_at, t.created_by
    FROM transactions t
    WHERE DATE(t.created_at) BETWEEN p_start_date AND p_end_date
      AND (p_acc_id IS NULL OR t.acc_id = p_acc_id)
      AND (p_transaction_type IS NULL OR t.type = p_transaction_type)
    ORDER BY t.created_at DESC;
END;
$$ LANGUAGE plpgsql;

-- Function to get branch-wise transaction report (NEW with UUID types)
CREATE FUNCTION get_branch_transaction_report(
    p_branch_id UUID,
    p_start_date DATE,
    p_end_date DATE,
    p_transaction_type VARCHAR DEFAULT NULL
)
RETURNS TABLE(
    branch_id UUID,
    branch_name VARCHAR,
    total_deposits NUMERIC,
    total_withdrawals NUMERIC,
    total_transfers NUMERIC,
    transaction_count BIGINT
) AS
$$
BEGIN
    RETURN QUERY
    SELECT 
        b.branch_id,
        b.branch_name,
        COALESCE(SUM(CASE WHEN t.type = 'Deposit' THEN t.amount ELSE 0 END), 0) as total_deposits,
        COALESCE(SUM(CASE WHEN t.type = 'Withdrawal' THEN t.amount ELSE 0 END), 0) as total_withdrawals,
        COALESCE(SUM(CASE WHEN t.type = 'BankTransfer' THEN t.amount ELSE 0 END), 0) as total_transfers,
        COUNT(t.transaction_id) as transaction_count
    FROM branch b
    LEFT JOIN account a ON b.branch_id = a.branch_id
    LEFT JOIN transactions t ON a.acc_id = t.acc_id 
        AND DATE(t.created_at) BETWEEN p_start_date AND p_end_date
        AND (p_transaction_type IS NULL OR t.type = p_transaction_type)
    WHERE b.branch_id = p_branch_id
    GROUP BY b.branch_id, b.branch_name;
END;
$$ LANGUAGE plpgsql;

-- Function to calculate daily/monthly transaction totals (NEW with UUID types)
CREATE FUNCTION calculate_transaction_totals(
    p_acc_id UUID,
    p_period VARCHAR,
    p_start_date DATE DEFAULT NULL,
    p_end_date DATE DEFAULT NULL
)
RETURNS TABLE(
    summary_date DATE,
    year INTEGER,
    month INTEGER,
    total_deposits NUMERIC,
    total_withdrawals NUMERIC,
    total_transfers NUMERIC,
    transaction_count BIGINT
) AS
$$
BEGIN
    IF p_period = 'daily' THEN
        RETURN QUERY
        SELECT 
            DATE(t.created_at) as summary_date,
            NULL::INTEGER as year,
            NULL::INTEGER as month,
            COALESCE(SUM(CASE WHEN t.type = 'Deposit' THEN t.amount ELSE 0 END), 0) as total_deposits,
            COALESCE(SUM(CASE WHEN t.type = 'Withdrawal' THEN t.amount ELSE 0 END), 0) as total_withdrawals,
            COALESCE(SUM(CASE WHEN t.type = 'BankTransfer' THEN t.amount ELSE 0 END), 0) as total_transfers,
            COUNT(t.transaction_id) as transaction_count
        FROM transactions t
        WHERE t.acc_id = p_acc_id
          AND (p_start_date IS NULL OR DATE(t.created_at) >= p_start_date)
          AND (p_end_date IS NULL OR DATE(t.created_at) <= p_end_date)
        GROUP BY DATE(t.created_at)
        ORDER BY DATE(t.created_at) DESC;
    ELSE -- monthly
        RETURN QUERY
        SELECT 
            NULL::DATE as summary_date,
            EXTRACT(YEAR FROM t.created_at)::INTEGER as year,
            EXTRACT(MONTH FROM t.created_at)::INTEGER as month,
            COALESCE(SUM(CASE WHEN t.type = 'Deposit' THEN t.amount ELSE 0 END), 0) as total_deposits,
            COALESCE(SUM(CASE WHEN t.type = 'Withdrawal' THEN t.amount ELSE 0 END), 0) as total_withdrawals,
            COALESCE(SUM(CASE WHEN t.type = 'BankTransfer' THEN t.amount ELSE 0 END), 0) as total_transfers,
            COUNT(t.transaction_id) as transaction_count
        FROM transactions t
        WHERE t.acc_id = p_acc_id
          AND (p_start_date IS NULL OR DATE(t.created_at) >= p_start_date)
          AND (p_end_date IS NULL OR DATE(t.created_at) <= p_end_date)
        GROUP BY EXTRACT(YEAR FROM t.created_at), EXTRACT(MONTH FROM t.created_at)
        ORDER BY year DESC, month DESC;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- Function to get all transactions with account details (NEW with UUID types)
CREATE FUNCTION get_all_transactions_with_account_details(
    p_limit INTEGER,
    p_offset INTEGER
)
RETURNS TABLE(
    transaction_id UUID,
    amount NUMERIC,
    acc_id UUID,
    type transaction_type,
    description TEXT,
    reference_no BIGINT,
    created_at TIMESTAMP,
    created_by UUID,
    acc_holder_name VARCHAR,
    branch_id UUID
) AS
$$
BEGIN
    RETURN QUERY
    SELECT 
        t.transaction_id, t.amount, t.acc_id, t.type, t.description, 
        t.reference_no, t.created_at, t.created_by,
        c.full_name as account_holder_name, a.branch_id
    FROM transactions t
    LEFT JOIN account a ON t.acc_id = a.acc_id
    LEFT JOIN accounts_owner ao ON a.acc_id = ao.acc_id
    LEFT JOIN customer c ON ao.customer_id = c.customer_id
    ORDER BY t.created_at DESC
    LIMIT p_limit OFFSET p_offset;
END;
$$ LANGUAGE plpgsql;

-- Function to process money transfer between accounts with auto-generation and rollback
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
        -- Generate new UUID for transaction
        new_transaction_id := gen_random_uuid();
        
        -- Generate new reference number (using epoch seconds + random number)
        new_reference_no := EXTRACT(EPOCH FROM NOW())::BIGINT * 1000 + (RANDOM() * 1000)::BIGINT;
        
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
        
        -- Insert bank transfer transaction for source account (debits from source)
        INSERT INTO transactions (transaction_id, amount, acc_id, type, description, reference_no, created_at, created_by)
        VALUES (gen_random_uuid(), -p_amount, p_from_acc_id, 'BankTransfer', p_description, new_reference_no, NOW(), p_created_by);
        
        -- Insert bank transfer transaction for destination account (credits to destination)
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