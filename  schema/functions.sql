CREATE OR REPLACE FUNCTION create_user(
    p_nic VARCHAR,
    p_first_name VARCHAR,
    p_last_name VARCHAR,
    p_address VARCHAR,
    p_phone_number VARCHAR,
    p_username VARCHAR,
    p_hashed_password VARCHAR
)
RETURNS UUID AS
$$
DECLARE
    new_user_id UUID;
    new_activity_id UUID;
BEGIN
    BEGIN
        -- 1. Create activity log first
        INSERT INTO activity (logs)
        VALUES ('New user created')
        RETURNING activity_id INTO new_activity_id;

        -- 2. Insert into users (UUID auto)
        INSERT INTO users (
            nic, first_name, last_name, address, phone_number, activity_id
        )
        VALUES (
            p_nic, p_first_name, p_last_name, p_address, p_phone_number, new_activity_id
        )
        RETURNING user_id INTO new_user_id;

        -- 3. Insert into login (UUID auto)
        INSERT INTO user_login (
            user_id, username, password, password_last_update
        )
        VALUES (
            new_user_id, p_username, p_hashed_password, NOW()
        );

        RETURN new_user_id;

    EXCEPTION
        WHEN OTHERS THEN
            RAISE EXCEPTION 'Error creating user: %', SQLERRM;
    END;
END;
$$ LANGUAGE plpgsql;






-- Add your other functions from  here

-- Function to process deposit transactions
CREATE OR REPLACE FUNCTION process_deposit_transaction(
    p_transaction_id UUID,
    p_acc_id UUID,
    p_amount NUMERIC,
    p_description TEXT,
    p_reference_no VARCHAR,
    p_created_by UUID
)
RETURNS TABLE(transaction_id UUID, new_balance NUMERIC, success BOOLEAN) AS
$$
DECLARE
    current_balance NUMERIC;
    updated_balance NUMERIC;
BEGIN
    -- Get current balance
    SELECT balance INTO current_balance FROM account WHERE acc_id = p_acc_id;
    
    IF current_balance IS NULL THEN
        RETURN QUERY SELECT p_transaction_id, 0::NUMERIC, FALSE;
        RETURN;
    END IF;
    
    -- Calculate new balance
    updated_balance := current_balance + p_amount;
    
    -- Insert transaction record
    INSERT INTO transactions (transaction_id, amount, acc_id, type, description, reference_no, created_at, created_by)
    VALUES (p_transaction_id, p_amount, p_acc_id, 'Deposit', p_description, p_reference_no, NOW(), p_created_by);
    
    -- Update account balance
    UPDATE account SET balance = updated_balance WHERE acc_id = p_acc_id;
    
    RETURN QUERY SELECT p_transaction_id, updated_balance, TRUE;
EXCEPTION
    WHEN OTHERS THEN
        RETURN QUERY SELECT p_transaction_id, current_balance, FALSE;
END;
$$ LANGUAGE plpgsql;

-- Function to process withdrawal transactions
CREATE OR REPLACE FUNCTION process_withdrawal_transaction(
    p_transaction_id UUID,
    p_acc_id UUID,
    p_amount NUMERIC,
    p_description TEXT,
    p_reference_no VARCHAR,
    p_created_by UUID
)
RETURNS TABLE(transaction_id UUID, new_balance NUMERIC, success BOOLEAN, error_message TEXT) AS
$$
DECLARE
    current_balance NUMERIC;
    updated_balance NUMERIC;
BEGIN
    -- Get current balance
    SELECT balance INTO current_balance FROM account WHERE acc_id = p_acc_id;
    
    IF current_balance IS NULL THEN
        RETURN QUERY SELECT p_transaction_id, 0::NUMERIC, FALSE, 'Account not found'::TEXT;
        RETURN;
    END IF;
    
    -- Check sufficient funds
    IF current_balance < p_amount THEN
        RETURN QUERY SELECT p_transaction_id, current_balance, FALSE, 'Insufficient funds'::TEXT;
        RETURN;
    END IF;
    
    -- Calculate new balance
    updated_balance := current_balance - p_amount;
    
    -- Insert transaction record
    INSERT INTO transactions (transaction_id, amount, acc_id, type, description, reference_no, created_at, created_by)
    VALUES (p_transaction_id, p_amount, p_acc_id, 'Withdrawal', p_description, p_reference_no, NOW(), p_created_by);
    
    -- Update account balance
    UPDATE account SET balance = updated_balance WHERE acc_id = p_acc_id;
    
    RETURN QUERY SELECT p_transaction_id, updated_balance, TRUE, NULL::TEXT;
EXCEPTION
    WHEN OTHERS THEN
        RETURN QUERY SELECT p_transaction_id, current_balance, FALSE, SQLERRM::TEXT;
END;
$$ LANGUAGE plpgsql;

-- Function to get transaction history by account

CREATE OR REPLACE FUNCTION get_transaction_history_by_account(
    p_acc_id UUID,
    p_limit INTEGER,
    p_offset INTEGER
)
RETURNS TABLE(
    transaction_id UUID,
    amount NUMERIC(12,2),
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
    SELECT 
        t.transaction_id, 
        t.amount, 
        t.acc_id, 
        t.type, 
        t.description, 
        t.reference_no, 
        t.created_at, 
        t.created_by
    FROM transactions t
    WHERE t.acc_id = p_acc_id
    ORDER BY t.created_at DESC
    LIMIT p_limit OFFSET p_offset;
END;
$$ LANGUAGE plpgsql;


-- Function to get transaction history by date range
CREATE OR REPLACE FUNCTION get_transaction_history_by_date_range(
    p_start_date DATE,
    p_end_date DATE,
    p_acc_id UUID DEFAULT NULL,
    p_transaction_type VARCHAR DEFAULT NULL
)
RETURNS TABLE(
    transaction_id UUID,
    amount NUMERIC,
    acc_id UUID,
    type VARCHAR,
    description TEXT,
    reference_no VARCHAR,
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

-- Function to get branch-wise transaction report
CREATE OR REPLACE FUNCTION get_branch_transaction_report(
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
        COALESCE(SUM(CASE WHEN t.type = 'banktransfer' THEN t.amount ELSE 0 END), 0) as total_transfers,
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

-- Function to calculate daily/monthly transaction totals
CREATE OR REPLACE FUNCTION calculate_transaction_totals(
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
            COALESCE(SUM(CASE WHEN t.type = 'banktransfer' THEN t.amount ELSE 0 END), 0) as total_transfers,
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
            COALESCE(SUM(CASE WHEN t.type = 'banktransfer' THEN t.amount ELSE 0 END), 0) as total_transfers,
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

-- Function to get all transactions with account details
CREATE OR REPLACE FUNCTION get_all_transactions_with_account_details(
    p_limit INTEGER,
    p_offset INTEGER
)
RETURNS TABLE(
    transaction_id UUID,
    amount NUMERIC,
    acc_id UUID,
    type VARCHAR,
    description TEXT,
    reference_no VARCHAR,
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