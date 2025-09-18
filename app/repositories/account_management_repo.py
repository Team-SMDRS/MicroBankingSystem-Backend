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

    def create_customer_with_login(self, customer_data, login_data, created_by_user_id):
        """
        Create a customer and customer_login.
        Returns: customer_id
        """
        # Insert customer
        self.cursor.execute(
            """
            INSERT INTO customer (
                full_name, address, phone_number, nic, created_by, updated_by
            ) VALUES (%s, %s, %s, %s, %s, %s)
            RETURNING customer_id;
            """,
            (
                customer_data['full_name'],
                customer_data.get('address'),
                customer_data.get('phone_number'),
                customer_data['nic'],
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
                account_no, branch_id, savings_plan_id, balance, created_by, updated_by
            ) VALUES (%s, %s, %s, %s, %s, %s)
            RETURNING acc_id;
            """,
            (
                account_data['account_no'],
                account_data.get('branch_id'),
                account_data.get('savings_plan_id'),
                account_data.get('balance', 0.0),
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