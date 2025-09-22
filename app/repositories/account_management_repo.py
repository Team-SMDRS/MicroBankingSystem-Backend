from psycopg2.extras import RealDictCursor


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
    
    def create_account_for_existing_customer_by_nic(self, account_data, nic, created_by_user_id):
        """
        Create a new account for an existing customer using NIC.
        Returns: acc_id if successful, None if customer not found.
        """
        # Find customer_id by NIC
        self.cursor.execute(
            "SELECT customer_id FROM customer WHERE nic = %s",
            (nic,)
        )
        row = self.cursor.fetchone()
        if not row:
            return None  # Customer not found
        customer_id = row['customer_id']
        # Create account and link to customer
        return self.create_account_for_customer(account_data, customer_id, created_by_user_id)

    def create_customer_with_login(self, customer_data, login_data, created_by_user_id):
        """
        Create a customer and customer_login.
        Returns: customer_id
        """
        # Insert customer
        self.cursor.execute(
            """
            INSERT INTO customer (
                full_name, address, phone_number, nic, dob, created_by, updated_by
            ) VALUES (%s, %s, %s, %s, %s, %s, %s)
            RETURNING customer_id;
            """,
            (
                customer_data['full_name'],
                customer_data.get('address'),
                customer_data.get('phone_number'),
                customer_data['nic'],
                customer_data['dob'],
                created_by_user_id,
                created_by_user_id
            )
        )
        customer_row = self.cursor.fetchone()
        customer_id = customer_row['customer_id']

        # Insert customer_login
        self.cursor.execute(
            """
            INSERT INTO customer_login (
                customer_id, username, password, created_by, updated_by
            ) VALUES (%s, %s, %s, %s, %s)
            RETURNING login_id;
            """,
            (
                customer_id,
                login_data['username'],
                login_data['password'],  # should be hashed
                created_by_user_id,
                created_by_user_id
            )
        )
        self.conn.commit()
        return customer_id

    def create_account_for_customer(self, account_data, customer_id, created_by_user_id):
        """
        Create an account and link it to a customer.
        Returns: acc_id
        """
        # Insert account
        self.cursor.execute(
            """
            INSERT INTO account (
                account_no, branch_id, savings_plan_id, balance, status, created_by, updated_by
            ) VALUES (%s, %s, %s, %s, %s, %s, %s)
            RETURNING acc_id;
            """,
            (
                account_data['account_no'],
                account_data.get('branch_id'),
                account_data.get('savings_plan_id'),
                account_data.get('balance', 0.0),
                account_data.get('status', 'active'),
                created_by_user_id,
                created_by_user_id
            )
        )
        acc_row = self.cursor.fetchone()
        acc_id = acc_row['acc_id']

        # Link customer and account
        self.cursor.execute(
            """
            INSERT INTO accounts_owner (acc_id, customer_id)
            VALUES (%s, %s)
            """,
            (acc_id, customer_id)
        )
        self.conn.commit()
        return acc_id

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
            ''',
            (account_no,)
        )
        return self.cursor.fetchone()

    def update_account(self, account_no, update_data):
        # Only allow updating savings_plan_id
        if "savings_plan_id" not in update_data:
            return None
        sql = "UPDATE account SET savings_plan_id = %s WHERE account_no = %s RETURNING *"
        self.cursor.execute(sql, (update_data["savings_plan_id"], account_no))
        self.conn.commit()
        return self.cursor.fetchone()
    
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