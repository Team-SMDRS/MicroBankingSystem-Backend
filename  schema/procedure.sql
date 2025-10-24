CREATE OR REPLACE PROCEDURE run_daily_fd_interest()
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM daily_fd_interest_check();
    COMMIT;
END;
$$;







CREATE FUNCTION public.daily_fd_interest_check() RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    PERFORM process_fd_interest_payment();
    
    RAISE NOTICE 'Daily FD interest check completed at %', CURRENT_TIMESTAMP;
END;
$$;





CREATE FUNCTION public.process_fd_interest_payment() RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    fd_record RECORD;
    interest_amount NUMERIC(24, 12);
    daily_rate NUMERIC(24, 12);
BEGIN
    -- Loop through all active FDs where today matches next_interest_day
    FOR fd_record IN 
        SELECT 
            fd.fd_id,
            fd.balance,
            fd.acc_id,
            fd.fd_plan_id,
            fd.next_interest_day,
            fd.fd_account_no,
            fp.interest_rate,
            a.account_no,
            a.balance as account_balance
        FROM 
            public.fixed_deposit fd
        INNER JOIN 
            public.fd_plan fp ON fd.fd_plan_id = fp.fd_plan_id
        INNER JOIN 
            public.account a ON fd.acc_id = a.acc_id
        WHERE 
            fd.status = 'active'
            AND fp.status = 'active'
            AND a.status = 'active'
            AND fd.next_interest_day = CURRENT_DATE
    LOOP
        -- Calculate daily interest rate (annual rate / 365)
        daily_rate := fd_record.interest_rate / 365.0 / 100.0;
        
        -- Calculate interest for 30 days
        interest_amount := fd_record.balance * daily_rate * 30;
        
        -- Round to 2 decimal places for transaction
        interest_amount := ROUND(interest_amount, 2);
        
        -- Insert interest transaction
        INSERT INTO public.transactions (
            amount,
            acc_id,
            type,
            description,
            created_at,
            created_by
        ) VALUES (
            interest_amount,
            fd_record.acc_id,
            'Deposit',
            'FD Interest - FD Account No: ' || fd_record.fd_account_no,
            CURRENT_TIMESTAMP,
            '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1'  -- System generated, so created_by is NULL
        );
        
        -- Update the linked savings account balance
        UPDATE public.account
        SET 
            balance = balance + interest_amount,
            updated_at = CURRENT_TIMESTAMP,
            updated_by = '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1'  -- System update
        WHERE 
            acc_id = fd_record.acc_id;
        
        -- Update FD next_interest_day to 30 days from now
        UPDATE public.fixed_deposit
        SET 
            next_interest_day = CURRENT_DATE + INTERVAL '30 days',
            updated_at = CURRENT_TIMESTAMP,
            updated_by = '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1'  -- System update
        WHERE 
            fd_id = fd_record.fd_id;
        
        -- Log the interest payment (optional)
        RAISE NOTICE 'Interest paid for FD %: Amount %, Next payment date %', 
            fd_record.fd_account_no, 
            interest_amount, 
            CURRENT_DATE + INTERVAL '30 days';
            
    END LOOP;
END;
$$;
