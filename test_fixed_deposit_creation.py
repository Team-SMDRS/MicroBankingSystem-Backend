"""
Test script for debugging fixed deposit creation
"""
import sys
import os
sys.path.insert(0, os.path.abspath('.'))

from app.database.db import get_db
from app.repositories.fixed_deposit_repo import FixedDepositRepository
from app.services.fixed_deposit_service import FixedDepositService

def test_create_fixed_deposit():
    """Test creating a fixed deposit"""
    print("=== Testing Fixed Deposit Creation ===\n")
    
    # Get database connection
    db = next(get_db())
    
    try:
        repo = FixedDepositRepository(db)
        service = FixedDepositService(repo)
        
        # Test parameters - REPLACE WITH YOUR ACTUAL VALUES
        savings_account_no = "1001"  # Replace with an actual savings account number
        amount = 10000.00
        plan_id = "YOUR_PLAN_UUID"  # Replace with an actual FD plan UUID
        
        print(f"Testing with:")
        print(f"  Savings Account: {savings_account_no}")
        print(f"  Amount: {amount}")
        print(f"  Plan ID: {plan_id}\n")
        
        # Step 1: Check if savings account exists
        print("Step 1: Validating savings account...")
        savings_account = repo.get_savings_account_by_account_no(savings_account_no)
        if savings_account:
            print(f"✓ Savings account found: {savings_account}")
            print(f"  Account ID: {savings_account['acc_id']}")
            print(f"  Balance: {savings_account['balance']}")
        else:
            print("✗ Savings account not found or inactive")
            return
        
        # Step 2: Check if FD plan exists
        print("\nStep 2: Validating FD plan...")
        fd_plan = repo.validate_fd_plan(plan_id)
        if fd_plan:
            print(f"✓ FD plan found: {fd_plan}")
            print(f"  Duration: {fd_plan['duration']} months")
            print(f"  Interest Rate: {fd_plan['interest_rate']}%")
        else:
            print("✗ FD plan not found or inactive")
            return
        
        # Step 3: Create fixed deposit
        print("\nStep 3: Creating fixed deposit...")
        result = service.create_fixed_deposit(
            savings_account_no=savings_account_no,
            amount=amount,
            plan_id=plan_id,
            created_by_user_id=None  # Set to actual user ID if needed
        )
        
        print(f"✓ Fixed deposit created successfully!")
        print(f"\nResult:")
        for key, value in result.items():
            print(f"  {key}: {value}")
        
    except Exception as e:
        print(f"\n✗ Error occurred: {type(e).__name__}")
        print(f"  Message: {str(e)}")
        import traceback
        print(f"\nFull traceback:")
        traceback.print_exc()
    
    finally:
        db.close()

if __name__ == "__main__":
    # First, let's list available FD plans and accounts
    print("=== Available FD Plans ===\n")
    db = next(get_db())
    try:
        repo = FixedDepositRepository(db)
        
        # Get active FD plans
        plans = repo.get_active_fd_plans()
        if plans:
            print("Active FD Plans:")
            for plan in plans:
                print(f"  Plan ID: {plan['fd_plan_id']}")
                print(f"    Duration: {plan['duration']} months")
                print(f"    Interest Rate: {plan['interest_rate']}%")
                print()
        else:
            print("No active FD plans found\n")
        
        print("=== Sample Accounts ===\n")
        # You may need to adjust this query based on your database
        repo.cursor.execute("""
            SELECT account_no, acc_id, balance, status 
            FROM account 
            WHERE status = 'active' 
            LIMIT 5
        """)
        accounts = repo.cursor.fetchall()
        if accounts:
            print("Sample Active Accounts:")
            for acc in accounts:
                print(f"  Account No: {acc['account_no']}")
                print(f"    Account ID: {acc['acc_id']}")
                print(f"    Balance: {acc['balance']}")
                print()
        
    finally:
        db.close()
    
    print("\n" + "="*50)
    print("Update the test_create_fixed_deposit() function with")
    print("actual values from above, then uncomment the line below")
    print("="*50 + "\n")
    
    # Uncomment to run the actual test:
    # test_create_fixed_deposit()
