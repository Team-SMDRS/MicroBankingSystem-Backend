#user repo .py


from psycopg2.extras import RealDictCursor

class CustomerRepository:
    def __init__(self, db_conn):
        self.conn = db_conn
        self.cursor = self.conn.cursor(cursor_factory=RealDictCursor)

    def get_customer_by_nic(self, nic: str):
        """
        Fetch basic customer info by NIC.
        Returns: dict or None
        """
        self.cursor.execute(
            "SELECT customer_id, full_name, nic FROM customer WHERE nic = %s",
            (nic,)
        )
        return self.cursor.fetchone()




    def get_customer_login_by_username(self, username: str):
        """
        Fetch a login row by username.
        """
        self.cursor.execute(
            "SELECT * FROM customer_login WHERE username = %s",
            (username,)
        )
        return self.cursor.fetchone()
    
    def get_customer_details_by_nic(self, nic: str):
        """
        Fetch customer details by NIC, including creator's name.
        Returns: dict or None
        """
        self.cursor.execute(
            '''
            SELECT c.customer_id, c.full_name, c.nic, c.address, c.phone_number, c.dob,
                   u.first_name || ' ' || u.last_name AS created_by_user_name
            FROM customer c
            LEFT JOIN users u ON c.created_by = u.user_id
            WHERE c.nic = %s
            '''
            , (nic,)
        )
        return self.cursor.fetchone()
    
    def get_customer_accounts(self, customer_id: str):
        """
        Get all accounts owned by a customer.
        Returns: list of account dicts
        """
        self.cursor.execute(
            '''
            SELECT 
                a.acc_id,
                a.account_no,
                a.balance,
                a.status,
                a.opened_date,
                b.name AS branch_name,
                b.branch_id,
                sp.plan_name AS savings_plan
            FROM accounts_owner ao
            JOIN account a ON ao.acc_id = a.acc_id
            JOIN branch b ON a.branch_id = b.branch_id
            JOIN savings_plan sp ON a.savings_plan_id = sp.savings_plan_id
            WHERE ao.customer_id = %s
            ORDER BY a.opened_date DESC
            ''',
            (customer_id,)
        )
        return self.cursor.fetchall()
    
    def get_customer_transactions(self, customer_id: str):
        """
        Get all transactions for accounts owned by a customer.
        Returns: list of transaction dicts
        """
        self.cursor.execute(
            '''
            SELECT 
                t.transaction_id,
                t.reference_no,
                t.amount,
                t.type,
                t.description,
                t.created_at,
                a.account_no
            FROM transactions t
            JOIN account a ON t.acc_id = a.acc_id
            JOIN accounts_owner ao ON a.acc_id = ao.acc_id
            WHERE ao.customer_id = %s
            ORDER BY t.created_at DESC
            ''',
            (customer_id,)
        )
        return self.cursor.fetchall()
    
    def get_customer_fixed_deposits(self, customer_id: str):
        """
        Get all fixed deposits for accounts owned by a customer.
        Returns: list of fixed deposit dicts
        """
        self.cursor.execute(
            '''
            SELECT 
                fd.fd_id,
                fd.fd_account_no,
                fd.balance,
                fd.opened_date,
                fd.maturity_date,
                fd.status,
                a.account_no AS linked_savings_account,
                fp.duration,
                fp.interest_rate,
                b.name AS branch_name
            FROM fixed_deposit fd
            JOIN account a ON fd.acc_id = a.acc_id
            JOIN accounts_owner ao ON a.acc_id = ao.acc_id
            JOIN fd_plan fp ON fd.fd_plan_id = fp.fd_plan_id
            JOIN branch b ON a.branch_id = b.branch_id
            WHERE ao.customer_id = %s
            ORDER BY fd.opened_date DESC
            ''',
            (customer_id,)
        )
        return self.cursor.fetchall()
    
    def get_customer_by_id(self, customer_id: str):
        """
        Fetch customer details by customer_id.
        Returns: dict or None
        """
        self.cursor.execute(
            '''
            SELECT 
                c.customer_id, 
                c.full_name, 
                c.nic, 
                c.address, 
                c.phone_number, 
                c.dob,
                c.created_at
            FROM customer c
            WHERE c.customer_id = %s
            ''',
            (customer_id,)
        )
        return self.cursor.fetchone()









