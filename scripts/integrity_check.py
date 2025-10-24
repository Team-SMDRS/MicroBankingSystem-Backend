#!/usr/bin/env python3
"""
Database integrity check script
Validates data consistency and reports issues
"""

import os
import psycopg2
from datetime import datetime
import logging
import json

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

def get_db_connection():
    """Establish database connection"""
    try:
        conn = psycopg2.connect(
            host=os.getenv('DB_HOST'),
            port=int(os.getenv('DB_PORT', 5432)),
            database=os.getenv('DB_NAME'),
            user=os.getenv('DB_USER'),
            password=os.getenv('DB_PASSWORD')
        )
        logger.info(f"✓ Connected to database at {os.getenv('DB_HOST')}")
        return conn
    except psycopg2.Error as e:
        logger.error(f"✗ Database connection failed: {str(e)}")
        raise

def check_orphaned_accounts(cur):
    """Check for accounts without customer owners"""
    try:
        logger.info("Checking for orphaned accounts...")
        cur.execute('''
            SELECT COUNT(*) as orphaned_count
            FROM account a
            WHERE NOT EXISTS (
                SELECT 1 FROM accounts_owner ao WHERE ao.acc_id = a.acc_id
            )
        ''')
        result = cur.fetchone()
        orphaned_count = result[0] if result else 0
        
        if orphaned_count > 0:
            logger.warning(f"  ⚠ Found {orphaned_count} orphaned accounts")
            return False
        else:
            logger.info("  ✓ No orphaned accounts found")
            return True
    except psycopg2.Error as e:
        logger.error(f"✗ Orphaned accounts check failed: {str(e)}")
        return False

def check_negative_balances(cur):
    """Check for accounts with negative balances"""
    try:
        logger.info("Checking for negative account balances...")
        cur.execute('''
            SELECT COUNT(*) as negative_count
            FROM account
            WHERE balance < 0
        ''')
        result = cur.fetchone()
        negative_count = result[0] if result else 0
        
        if negative_count > 0:
            logger.warning(f"  ⚠ Found {negative_count} accounts with negative balance")
            return False
        else:
            logger.info("  ✓ All account balances are valid")
            return True
    except psycopg2.Error as e:
        logger.error(f"✗ Negative balance check failed: {str(e)}")
        return False

def check_transaction_consistency(cur):
    """Verify transaction amounts are positive"""
    try:
        logger.info("Checking transaction consistency...")
        cur.execute('''
            SELECT COUNT(*) as invalid_count
            FROM transactions
            WHERE amount <= 0
        ''')
        result = cur.fetchone()
        invalid_count = result[0] if result else 0
        
        if invalid_count > 0:
            logger.warning(f"  ⚠ Found {invalid_count} transactions with invalid amounts")
            return False
        else:
            logger.info("  ✓ All transactions are valid")
            return True
    except psycopg2.Error as e:
        logger.error(f"✗ Transaction consistency check failed: {str(e)}")
        return False

def check_fixed_deposit_validity(cur):
    """Check fixed deposit records for consistency"""
    try:
        logger.info("Checking fixed deposit validity...")
        cur.execute('''
            SELECT COUNT(*) as invalid_count
            FROM fixed_deposit fd
            WHERE fd.balance <= 0
               OR fd.maturity_date <= fd.opened_date
               OR fd.fd_plan_id IS NULL
        ''')
        result = cur.fetchone()
        invalid_count = result[0] if result else 0
        
        if invalid_count > 0:
            logger.warning(f"  ⚠ Found {invalid_count} invalid fixed deposits")
            return False
        else:
            logger.info("  ✓ All fixed deposits are valid")
            return True
    except psycopg2.Error as e:
        logger.error(f"✗ Fixed deposit validity check failed: {str(e)}")
        return False

def get_database_statistics(cur):
    """Gather database statistics"""
    try:
        logger.info("\nGathering database statistics...")
        stats = {}
        
        # Count records
        tables = ['account', 'customer', 'transactions', 'fixed_deposit', 'branch']
        for table in tables:
            cur.execute(f'SELECT COUNT(*) FROM {table};')
            count = cur.fetchone()[0]
            stats[table] = count
            logger.info(f"  {table}: {count} records")
        
        return stats
    except psycopg2.Error as e:
        logger.error(f"✗ Statistics gathering failed: {str(e)}")
        return {}

def main():
    """Main execution function"""
    conn = None
    try:
        conn = get_db_connection()
        
        with conn.cursor() as cur:
            logger.info("\n" + "="*60)
            logger.info("DATABASE INTEGRITY CHECK")
            logger.info("="*60 + "\n")
            
            checks = {
                'orphaned_accounts': check_orphaned_accounts(cur),
                'negative_balances': check_negative_balances(cur),
                'transaction_consistency': check_transaction_consistency(cur),
                'fixed_deposit_validity': check_fixed_deposit_validity(cur),
            }
            
            stats = get_database_statistics(cur)
        
        # Print summary
        logger.info("\n" + "="*60)
        logger.info("INTEGRITY CHECK RESULTS")
        logger.info("="*60)
        for check_name, passed in checks.items():
            status = "✓ PASS" if passed else "✗ FAIL"
            logger.info(f"{check_name}: {status}")
        logger.info("="*60)
        
        # Exit with appropriate code
        if all(checks.values()):
            logger.info("\n✓ All integrity checks passed!")
            exit(0)
        else:
            logger.warning("\n⚠ Some integrity checks failed")
            exit(1)
    
    except Exception as e:
        logger.error(f"✗ Fatal error: {str(e)}")
        exit(2)
    
    finally:
        if conn:
            conn.close()
            logger.info("\nDatabase connection closed")

if __name__ == '__main__':
    main()
