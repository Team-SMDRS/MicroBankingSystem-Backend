#!/usr/bin/env python3
"""
Test script to check database connectivity and account existence
"""

try:
    # Import the database connection
    from app.database.db import get_db
    from app.repositories.transaction_management_repo import TransactionManagementRepository
    
    print("✅ Imports successful")
    
    # Test database connection
    conn = get_db()
    print("✅ Database connection successful")
    
    # Create repository instance
    repo = TransactionManagementRepository(conn)
    print("✅ Repository created")
    
    # Test the specific account
    acc_id = 'b5f4da28-9c88-4c2d-b648-fc63c709741c'
    exists = repo.account_exists(acc_id)
    print(f"Account {acc_id} exists: {exists}")
    
    if exists:
        balance = repo.get_account_balance(acc_id)
        print(f"Account balance: {balance}")
    else:
        # Get some sample accounts
        print("\n📋 Let's find some existing accounts:")
        conn.cursor().execute("SELECT acc_id, acc_holder_name, balance FROM account LIMIT 5")
        accounts = conn.cursor().fetchall()
        for acc in accounts:
            print(f"  - {acc[0]} | {acc[1]} | Balance: {acc[2]}")
    
    conn.close()
    
except ImportError as e:
    print(f"❌ Import error: {e}")
    print("Make sure you're in the correct directory and have all dependencies installed")
except Exception as e:
    print(f"❌ Error: {e}")
    print("This might be a database connection issue")