"""
Quick SQL queries to check fixed deposit creation issues
Run these in your PostgreSQL client (psql, pgAdmin, etc.)
"""

# Check if stored procedure exists
SELECT_PROCEDURE = """
SELECT 
    routine_name, 
    routine_type,
    data_type
FROM information_schema.routines 
WHERE routine_schema = 'public' 
AND routine_name = 'create_fixed_deposit';
"""

# Check active FD plans
CHECK_FD_PLANS = """
SELECT 
    fd_plan_id, 
    duration, 
    interest_rate, 
    status,
    created_at
FROM fd_plan 
WHERE status = 'active'
ORDER BY duration;
"""

# Check active accounts
CHECK_ACCOUNTS = """
SELECT 
    account_no, 
    acc_id, 
    balance, 
    status,
    opened_date
FROM account 
WHERE status = 'active' 
LIMIT 10;
"""

# Test the stored procedure directly
TEST_PROCEDURE = """
-- Replace the UUIDs with actual values from your database
SELECT * FROM create_fixed_deposit(
    'acc-id-uuid-here'::uuid,  -- Replace with actual account UUID
    10000.00,                   -- Amount
    'plan-id-uuid-here'::uuid,  -- Replace with actual plan UUID
    NULL                         -- Created by user ID (can be NULL)
);
"""

# Check recent fixed deposits
CHECK_RECENT_FDS = """
SELECT 
    fd.fd_id,
    fd.fd_account_no,
    fd.balance,
    fd.opened_date,
    fd.maturity_date,
    a.account_no as linked_savings_account,
    fp.duration,
    fp.interest_rate
FROM fixed_deposit fd
JOIN account a ON fd.acc_id = a.acc_id
JOIN fd_plan fp ON fd.fd_plan_id = fp.fd_plan_id
ORDER BY fd.opened_date DESC
LIMIT 5;
"""

# Check for errors in PostgreSQL logs
CHECK_ERRORS = """
-- Enable detailed error logging (run as superuser)
ALTER SYSTEM SET log_statement = 'all';
ALTER SYSTEM SET log_min_error_statement = 'info';
SELECT pg_reload_conf();

-- To reset later:
-- ALTER SYSTEM RESET log_statement;
-- ALTER SYSTEM RESET log_min_error_statement;
-- SELECT pg_reload_conf();
"""

if __name__ == "__main__":
    print("=== PostgreSQL Debugging Queries ===\n")
    print("1. Check if stored procedure exists:")
    print(SELECT_PROCEDURE)
    print("\n" + "="*70 + "\n")
    
    print("2. Check active FD plans:")
    print(CHECK_FD_PLANS)
    print("\n" + "="*70 + "\n")
    
    print("3. Check active accounts:")
    print(CHECK_ACCOUNTS)
    print("\n" + "="*70 + "\n")
    
    print("4. Test stored procedure directly:")
    print(TEST_PROCEDURE)
    print("\n" + "="*70 + "\n")
    
    print("5. Check recent fixed deposits:")
    print(CHECK_RECENT_FDS)
    print("\n" + "="*70 + "\n")
    
    print("6. Enable detailed logging (optional):")
    print(CHECK_ERRORS)
