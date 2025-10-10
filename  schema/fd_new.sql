
--close fixed deposit (mark as closed, balace set to zero and withdraw balance to linked savings account) before maturity or after maturity



CREATE OR REPLACE FUNCTION public.close_fixed_deposit
(
    p_fd_id UUID,
    p_closed_by UUID
)
RETURNS TABLE
(
    fd_id UUID,
    fd_account_no VARCHAR,
    balance DECIMAL,
    acc_id UUID,
    opened_date TIMESTAMP
WITH TIME ZONE,
    maturity_date TIMESTAMP
WITH TIME ZONE,
    closed_date TIMESTAMP
WITH TIME ZONE,
    status VARCHAR,
    transaction_id UUID,
    transaction_type VARCHAR,
    amount DECIMAL,
    description TEXT
) AS $$
DECLARE
    v_savings_acc_id UUID;
    v_fd_balance DECIMAL;
    v_transaction_id UUID;
BEGIN
    -- Lock and verify the fixed deposit record
    SELECT acc_id, balance
    INTO v_savings_acc_id
    , v_fd_balance
    FROM fixed_deposit
    WHERE fd_id = p_fd_id AND status = 'active'
    FOR
    UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Fixed deposit not found or not active';
END
IF;

    -- Create transaction record (FD payout to savings)
    -- Note: the project uses the "transactions" table (plural) with columns: amount, acc_id, type, description, created_at, created_by
    INSERT INTO transactions
    (
    amount,
    acc_id,
    type,
    description,
    created_at,
    created_by
    )
VALUES
    (
        v_fd_balance,
        v_savings_acc_id,
        'Deposit',
        'Fixed Deposit closure payout',
        CURRENT_TIMESTAMP,
        p_closed_by
    )
RETURNING transaction_id INTO v_transaction_id;

-- Update savings account balance
UPDATE account
    SET balance = balance + v_fd_balance,
        updated_at = CURRENT_TIMESTAMP,
        updated_by = p_closed_by
    WHERE acc_id = v_savings_acc_id;

-- Mark fixed deposit as closed (set to a valid enum value) and zero balance
UPDATE fixed_deposit
    SET balance = 0,
        status = 'inactive', -- use valid status_enum value (active/inactive)
        updated_at = CURRENT_TIMESTAMP,
        updated_by = p_closed_by
    WHERE fd_id = p_fd_id
    RETURNING
        fd_id,
        fd_account_no,
        balance,
        acc_id,
        opened_date,
        maturity_date,
        status
    INTO
        fd_id,
        fd_account_no,
        balance,
        acc_id,
        opened_date,
        maturity_date,
        status;

-- Return closure details with transaction info
transaction_id := v_transaction_id;
    transaction_type := 'Deposit';
    amount := v_fd_balance;
    description := 'Fixed Deposit closure payout';
RETURN NEXT;
END;
$$ LANGUAGE plpgsql;
