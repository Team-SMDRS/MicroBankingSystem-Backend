from psycopg2.extras import RealDictCursor

import bcrypt

class AccountManagementRepository:
    
    
    
    
    
    
    def __init__(self, db_conn):
        self.conn = db_conn
        self.cursor = self.conn.cursor(cursor_factory=RealDictCursor)

    def get_savings_plan_id_by_name(self, savings_plan_name):
        self.cursor.execute(
            "SELECT savings_plan_id FROM savings_plan WHERE TRIM(LOWER(plan_name)) = TRIM(LOWER(%s))",
            (savings_plan_name,)
        )
        row = self.cursor.fetchone()
        return row['savings_plan_id'] if row else None
    
    def get_customer_by_id(self, customer_id):
        """
        Fetch current values of allowed fields for a customer.
        """
        sql = "SELECT full_name, address, phone_number, nic FROM customer WHERE customer_id = %s"
        self.cursor.execute(sql, (customer_id,))
        return self.cursor.fetchone()
    
    
    def create_account_for_existing_customer_by_nic(self, account_data, nic, created_by_user_id):
        """
        Create a new account for an existing customer using NIC via PostgreSQL function.
        Returns: (acc_id, account_no) if successful, None if customer not found.
        """
        try:
            self.cursor.execute(
                """
                SELECT * FROM create_account_for_existing_customer_by_nic(
                    %s, %s, %s, %s, %s, %s
                )
                """,
                (
                    nic,
                    account_data.get('branch_id'),
                    account_data.get('savings_plan_id'),
                    created_by_user_id,
                    account_data.get('balance', 0.0),
                    account_data.get('status', 'active')
                )
            )
            
            result = self.cursor.fetchone()
            self.conn.commit()
            
            if result:
                return result['acc_id'], result['account_no']
            else:
                return None
                
        except Exception as e:
            self.conn.rollback()
            if "Customer not found" in str(e):
                return None
            raise e


       


    def create_customer_with_login(self, customer_data, login_data, created_by_user_id, account_data):
        """
        Calls the Postgres function to create account, customer, link, and login.
        Returns: (customer_id, account_no)
        """
        try:
            # Hash password before sending to DB
           # hashed_password = bcrypt.hashpw(login_data['password'].encode('utf-8'), bcrypt.gensalt())

            self.cursor.execute(
                """
                SELECT * FROM create_customer_with_login(
                    %s, %s, %s, %s, %s,  -- customer
                    %s, %s,              -- login
                    %s, %s, %s, %s,      -- account
                    %s                   -- created_by
                );
                """,
                (
                    customer_data['full_name'],
                    customer_data.get('address'),
                    customer_data.get('phone_number'),
                    customer_data['nic'],
                    customer_data['dob'],

                    login_data['username'],
                    login_data['password'],

                    account_data.get('branch_id'),
                    account_data.get('savings_plan_id'),
                    account_data.get('balance', 0.0),
                    

                    created_by_user_id,
                    account_data.get('status', 'active'),
                )
            )

            row = self.cursor.fetchone()
            self.conn.commit()

            return row['customer_id'], row['account_no']

        except Exception as e:
            self.conn.rollback()
            raise e

  


    def get_account_details_by_account_no(self, account_no):
        """
        Get customer names, account id, branch name, branch id, balance, and account type using account_no.
        Returns: dict with customer_names as comma-separated string or None if not found.
        """
        self.cursor.execute(
            """
            SELECT 
            STRING_AGG(c.full_name, ', ') AS customer_names,
            STRING_AGG(c.nic, ', ') AS customer_nics,
            STRING_AGG(c.phone_number, ', ') AS customer_phone_numbers,
            STRING_AGG(c.address, ', ') AS customer_addresses,
            a.acc_id AS account_id,
            b.name AS branch_name,
            b.branch_id,
            a.balance,
            a.status,
            sp.plan_name AS account_type
            FROM account a
            JOIN accounts_owner ao ON a.acc_id = ao.acc_id
            JOIN customer c ON ao.customer_id = c.customer_id
            JOIN branch b ON a.branch_id = b.branch_id
            JOIN savings_plan sp ON a.savings_plan_id = sp.savings_plan_id
            WHERE a.account_no = %s
            GROUP BY a.acc_id, b.name, b.branch_id, a.balance, sp.plan_name
            """,
            (account_no,)
        )
        return self.cursor.fetchone()

    # You can add get/update methods as needed, following this pattern.

    def get_accounts_by_branch(self, branch_id):
        """
        Get all accounts for a specific branch.
        Returns: List of account records.
        """
        self.cursor.execute(
            """
            SELECT * FROM account
            WHERE branch_id = %s
            ORDER BY created_at DESC
            """,
            (branch_id,)
        )
        return self.cursor.fetchall()
    
    def get_account_balance_by_account_no(self, account_no):
        """
        Get the balance for a specific account by account number.
        Returns: balance (float) or None if not found.
        """
        self.cursor.execute(
            """
            SELECT balance FROM account
            WHERE account_no = %s
            """,
            (account_no,)
        )
        row = self.cursor.fetchone()
        return row['balance'] if row else None
    

    def get_account_owner(self, account_no):
        self.cursor.execute(
            '''
            SELECT c.* FROM accounts_owner ao
            JOIN customer c ON ao.customer_id = c.customer_id
            JOIN account a ON ao.acc_id = a.acc_id
            WHERE a.account_no = %s
            '''
            , (account_no,)
        )
        return self.cursor.fetchall()

    def close_account_by_account_no(self, account_no, closed_by_user_id=None):
        """
        Mark an account status as 'closed' by its account_no.
        Optionally set updated_by to the user who closed the account.
        Before closing, returns the previous balance and the updated account row (dict) if successful,
        or None if account not found.
        """
        try:
            # Lock the account row to avoid race conditions and read the current balance
            self.cursor.execute(
                '''
                SELECT acc_id, balance, status FROM account
                WHERE account_no = %s
                FOR UPDATE
                ''',
                (account_no,)
            )
            current = self.cursor.fetchone()
            if not current:
                self.conn.rollback()
                return None

            previous_balance = current.get('balance', 0)

            # Perform update: set balance to 0 and mark status closed
            if closed_by_user_id:
                self.cursor.execute(
                    '''
                    UPDATE account
                    SET balance = 0, status = 'closed', updated_by = %s, updated_at = CURRENT_TIMESTAMP
                    WHERE account_no = %s
                    RETURNING *
                    ''',
                    (closed_by_user_id, account_no)
                )
            else:
                self.cursor.execute(
                    '''
                    UPDATE account
                    SET balance = 0, status = 'closed', updated_at = CURRENT_TIMESTAMP
                    WHERE account_no = %s
                    RETURNING *
                    ''',
                    (account_no,)
                )

            updated = self.cursor.fetchone()
            if not updated:
                self.conn.rollback()
                return None

            # Now fetch the selected fields including savings plan name
            self.cursor.execute(
                '''
                SELECT a.account_no, sp.plan_name AS savings_plan_name, a.updated_at, a.status
                FROM account a
                LEFT JOIN savings_plan sp ON a.savings_plan_id = sp.savings_plan_id
                WHERE a.account_no = %s
                ''',
                (account_no,)
            )
            selected = self.cursor.fetchone()
            if selected:
                self.conn.commit()
                return {"previous_balance": previous_balance, **selected}
            else:
                self.conn.commit()
                # If for any reason selected row is missing, return previous balance and updated row
                return {"previous_balance": previous_balance, "account": updated}
        except Exception:
            self.conn.rollback()
            raise
    
    def get_accounts_by_nic(self, nic):
        """
        Get all accounts for a given NIC number.
        Returns: List of account records.
        """
        # Select account fields except branch_id and savings_plan_id, and include human-readable names
        self.cursor.execute(
            '''
            SELECT
                a.acc_id,
                a.account_no,
                a.balance,
                a.opened_date,
                a.created_at,
                a.updated_at,
                a.created_by,
                a.updated_by,
                a.status,
                b.name AS branch_name,
                sp.plan_name AS savings_plan_name
            FROM account a
            JOIN accounts_owner ao ON a.acc_id = ao.acc_id
            JOIN customer c ON ao.customer_id = c.customer_id
            LEFT JOIN branch b ON a.branch_id = b.branch_id
            LEFT JOIN savings_plan sp ON a.savings_plan_id = sp.savings_plan_id
            WHERE c.nic = %s
            ORDER BY a.created_at DESC
            ''',
            (nic,)
        )
        return self.cursor.fetchall()

    
    def update_customer(self, customer_id, update_data):
        # Only allow updating certain fields
        allowed_fields = {"full_name", "address", "phone_number", "nic"}
        set_clauses = []
        values = []
        for key, value in update_data.items():
            if key in allowed_fields and value is not None:
                set_clauses.append(f"{key} = %s")
                values.append(value)
        if not set_clauses:
            return None
        values.append(customer_id)
        sql = f"UPDATE customer SET {', '.join(set_clauses)} WHERE customer_id = %s RETURNING *"
        self.cursor.execute(sql, tuple(values))
        self.conn.commit()
        return self.cursor.fetchone()

    def get_all_accounts(self):
        self.cursor.execute("SELECT * FROM account ORDER BY created_at DESC")
        return self.cursor.fetchall()
    
    def get_account_count_by_branch(self, branch_id):
        """
        Get the total number of accounts for a specific branch, and the branch name.
        Returns: dict with branch_name and account_count.
        """
        self.cursor.execute(
            """
            SELECT b.name AS branch_name, COUNT(a.acc_id) AS account_count
            FROM branch b
            LEFT JOIN account a ON a.branch_id = b.branch_id
            WHERE b.branch_id = %s
            GROUP BY b.name
            """,
            (branch_id,)
        )
        row = self.cursor.fetchone()
        return row if row else {"branch_name": None, "account_count": 0}
    
    
    def get_total_account_count(self):
        """
        Get the total number of accounts in the system.
        Returns: Integer count of all accounts.
        """
        self.cursor.execute(
            "SELECT COUNT(*) AS account_count FROM account"
        )
        row = self.cursor.fetchone()
        return row['account_count'] if row else 0
    

    
    
