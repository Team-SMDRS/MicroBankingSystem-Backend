#!/usr/bin/env python3
"""
Script to run scheduled database functions
Executed by GitHub Actions workflow
"""

import os
import psycopg2
from datetime import datetime
import logging

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

def run_monthly_interest_calculation(cur):
    """Run monthly interest calculation function"""
    try:
        logger.info("Running calculate_monthly_interest()...")
        cur.execute('SELECT calculate_monthly_interest();')
        logger.info("✓ Monthly interest calculation completed successfully")
        return True
    except psycopg2.Error as e:
        logger.error(f"✗ Monthly interest calculation failed: {str(e)}")
        return False

def run_cleanup_expired_tokens(cur):
    """Run cleanup of expired refresh tokens"""
    try:
        logger.info("Running cleanup_expired_user_refresh_tokens()...")
        cur.execute('SELECT cleanup_expired_user_refresh_tokens();')
        result = cur.fetchone()
        deleted_count = result[0] if result else 0
        logger.info(f"✓ Cleaned up {deleted_count} expired tokens")
        return True
    except psycopg2.Error as e:
        logger.error(f"✗ Token cleanup failed: {str(e)}")
        return False

def run_transaction_summary_update(cur):
    """Run transaction summary calculation"""
    try:
        logger.info("Running transaction summary updates...")
        # Get all active accounts
        cur.execute('SELECT acc_id FROM account WHERE status = %s;', ('active',))
        accounts = cur.fetchall()
        
        success_count = 0
        for (acc_id,) in accounts:
            try:
                cur.execute(
                    'SELECT * FROM calculate_transaction_totals(%s, %s);',
                    (acc_id, 'monthly')
                )
                success_count += 1
            except psycopg2.Error as e:
                logger.warning(f"  Warning: Transaction summary for account {acc_id} failed: {str(e)}")
        
        logger.info(f"✓ Transaction summary updated for {success_count} accounts")
        return True
    except psycopg2.Error as e:
        logger.error(f"✗ Transaction summary update failed: {str(e)}")
        return False

def main():
    """Main execution function"""
    conn = None
    try:
        conn = get_db_connection()
        
        with conn.cursor() as cur:
            results = {
                'monthly_interest': run_monthly_interest_calculation(cur),
                'token_cleanup': run_cleanup_expired_tokens(cur),
                'transaction_summary': run_transaction_summary_update(cur)
            }
            
            conn.commit()
        
        # Print summary
        logger.info("\n" + "="*60)
        logger.info("SCHEDULED FUNCTIONS EXECUTION SUMMARY")
        logger.info("="*60)
        for function_name, success in results.items():
            status = "✓ SUCCESS" if success else "✗ FAILED"
            logger.info(f"{function_name}: {status}")
        logger.info("="*60)
        
        # Exit with appropriate code
        if all(results.values()):
            logger.info("All functions executed successfully!")
            exit(0)
        else:
            logger.warning("Some functions failed during execution")
            exit(1)
    
    except Exception as e:
        logger.error(f"✗ Fatal error: {str(e)}")
        exit(2)
    
    finally:
        if conn:
            conn.close()
            logger.info("Database connection closed")

if __name__ == '__main__':
    main()
