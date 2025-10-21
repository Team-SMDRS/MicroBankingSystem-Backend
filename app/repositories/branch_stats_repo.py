from typing import Dict, List, Any, Optional
from psycopg2.extensions import connection
from psycopg2.extras import RealDictCursor

class BranchStatsRepository:
    def __init__(self, conn: connection):
        self.conn = conn
        self.cursor = conn.cursor(cursor_factory=RealDictCursor)

    def get_branch_account_statistics(self, branch_id: str) -> Dict[str, Any]:
        """
        Get comprehensive account statistics for a specific branch
        including joint accounts, fixed deposits, and savings accounts
        """
        try:
            self.cursor.execute(
                """
                WITH branch_info AS (
                    SELECT 
                        branch_id,
                        name as branch_name,
                        address as branch_address
                    FROM branch
                    WHERE branch_id = %s::UUID
                ),
                joint_accounts_stats AS (
                    SELECT 
                        a.acc_id,
                        a.balance
                    FROM account a
                    INNER JOIN accounts_owner ao ON a.acc_id = ao.acc_id
                    WHERE a.branch_id = %s::UUID
                    GROUP BY a.acc_id, a.balance
                    HAVING COUNT(ao.customer_id) > 1
                ),
                joint_accounts_summary AS (
                    SELECT 
                        COUNT(*) as total_joint_accounts,
                        COALESCE(SUM(balance), 0) as joint_accounts_balance
                    FROM joint_accounts_stats
                ),
                fixed_deposits_stats AS (
                    SELECT 
                        COUNT(*) as total_fixed_deposits,
                        COALESCE(SUM(fd.balance), 0) as fixed_deposits_amount
                    FROM fixed_deposit fd
                    INNER JOIN account a ON fd.acc_id = a.acc_id
                    WHERE a.branch_id = %s::UUID
                ),
                savings_accounts_stats AS (
                    SELECT 
                        COUNT(DISTINCT a.acc_id) as total_savings_accounts,
                        COALESCE(SUM(a.balance), 0) as savings_accounts_balance
                    FROM account a
                    WHERE a.branch_id = %s::UUID
                    AND a.acc_id NOT IN (
                        -- Exclude joint accounts
                        SELECT acc_id 
                        FROM accounts_owner 
                        GROUP BY acc_id 
                        HAVING COUNT(customer_id) > 1
                    )
                )
                SELECT 
                    bi.branch_id,
                    bi.branch_name,
                    bi.branch_address,
                    COALESCE(jas.total_joint_accounts, 0) as total_joint_accounts,
                    COALESCE(jas.joint_accounts_balance, 0) as joint_accounts_balance,
                    COALESCE(fds.total_fixed_deposits, 0) as total_fixed_deposits,
                    COALESCE(fds.fixed_deposits_amount, 0) as fixed_deposits_amount,
                    COALESCE(sas.total_savings_accounts, 0) as total_savings_accounts,
                    COALESCE(sas.savings_accounts_balance, 0) as savings_accounts_balance
                FROM branch_info bi
                LEFT JOIN joint_accounts_summary jas ON 1=1
                LEFT JOIN fixed_deposits_stats fds ON 1=1
                LEFT JOIN savings_accounts_stats sas ON 1=1
                """,
                (branch_id, branch_id, branch_id, branch_id)
            )
            
            result = self.cursor.fetchone()
            
            if result:
                return {
                    'branch_id': str(result['branch_id']),
                    'branch_name': result['branch_name'],
                    'branch_address': result.get('branch_address'),
                    'total_joint_accounts': int(result['total_joint_accounts']),
                    'joint_accounts_balance': float(result['joint_accounts_balance']),
                    'total_fixed_deposits': int(result['total_fixed_deposits']),
                    'fixed_deposits_amount': float(result['fixed_deposits_amount']),
                    'total_savings_accounts': int(result['total_savings_accounts']),
                    'savings_accounts_balance': float(result['savings_accounts_balance'])
                }
            
            return None
            
        except Exception as e:
            raise e

    def get_all_branches(self) -> List[Dict[str, Any]]:
        """
        Get list of all branches for dropdown selection
        """
        try:
            self.cursor.execute(
                """
                SELECT 
                    branch_id,
                    name as branch_name,
                    address as branch_address
                FROM branch
                ORDER BY name
                """
            )
            
            branches = self.cursor.fetchall()
            
            return [
                {
                    'branch_id': str(branch['branch_id']),
                    'branch_name': branch['branch_name'],
                    'branch_address': branch.get('branch_address')
                }
                for branch in branches
            ]
            
        except Exception as e:
            raise e
