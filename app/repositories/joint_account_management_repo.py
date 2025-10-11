from psycopg2.extras import RealDictCursor
import random
import string
from app.core.utils import hash_password

class JointAccountManagementRepository:
    
    def __init__(self, db_conn):
        self.conn = db_conn
        self.cursor = self.conn.cursor(cursor_factory=RealDictCursor)

    def get_joint_account_plan_id(self, plan_name):
        """Get savings plan ID by plan name (e.g., 'Joint')"""
        self.cursor.execute("SELECT savings_plan_id FROM savings_plan WHERE plan_name = %s", (plan_name,))
        row = self.cursor.fetchone()
        if not row:
            raise Exception(f"Savings plan '{plan_name}' not found")
        return str(row['savings_plan_id'])

    def _ensure_strings(self, account_data, created_by_user_id):
        """Normalize UUID-like values to strings so psycopg2 can adapt them."""
        if account_data is not None and 'savings_plan_id' in account_data:
            account_data['savings_plan_id'] = str(account_data['savings_plan_id'])
        created_by_user_id = str(created_by_user_id)
        return account_data, created_by_user_id

    def _generate_username(self, full_name):
        """Generate a unique username from full name"""
        base = ''.join(full_name.lower().split())
        suffix = ''.join(random.choices(string.digits, k=4))
        return f"{base}{suffix}"

    def _generate_password(self, length=8):
        """Generate a random password"""
        chars = string.ascii_letters + string.digits
        return ''.join(random.choices(chars, k=length))

    def create_joint_account(self, account_data, nic1, nic2, created_by_user_id):
        """
        Create a joint account for two customers by NICs.
        Status is always 'active'. Branch is set to the branch of the user creating the account.
        Returns: (acc_id, account_no) if successful, None if either customer not found.
        """
        try:
            account_data, created_by_user_id = self._ensure_strings(account_data, created_by_user_id)

            # Get customer IDs for both NICs
            self.cursor.execute("SELECT customer_id FROM customer WHERE nic = %s", (nic1,))
            row1 = self.cursor.fetchone()
            self.cursor.execute("SELECT customer_id FROM customer WHERE nic = %s", (nic2,))
            row2 = self.cursor.fetchone()
            if not row1 or not row2:
                return None
            customer_id1 = row1['customer_id']
            customer_id2 = row2['customer_id']

            # Get branch of the user creating the account from users_branch table
            self.cursor.execute("SELECT branch_id FROM users_branch WHERE user_id = %s", (created_by_user_id,))
            branch_row = self.cursor.fetchone()
            if not branch_row:
                return None
            branch_id = branch_row['branch_id']

            self.cursor.execute(
                """
                INSERT INTO account (branch_id, savings_plan_id, balance, status, created_by, updated_by)
                VALUES (%s, %s, %s, %s, %s, %s)
                RETURNING acc_id, account_no
                """,
                (
                    branch_id,
                    account_data['savings_plan_id'],
                    account_data.get('balance', 0.0),
                    'active',
                    created_by_user_id,
                    created_by_user_id
                )
            )
            acc_row = self.cursor.fetchone()
            acc_id = acc_row['acc_id']
            account_no = acc_row['account_no']

            self.cursor.execute(
                "INSERT INTO accounts_owner (acc_id, customer_id) VALUES (%s, %s), (%s, %s)",
                (acc_id, customer_id1, acc_id, customer_id2)
            )
            self.conn.commit()
            return acc_id, account_no
        except Exception as e:
            self.conn.rollback()
            raise e

    def create_joint_account_with_new_customers(self, customer1_data, customer2_data, account_data, created_by_user_id):
        """
        Create two new customers, auto-create their logins (generated username/password),
        create joint account, link both as owners.
        Returns: dict with customers and account info.
        """
        try:
            account_data, created_by_user_id = self._ensure_strings(account_data, created_by_user_id)

            # Insert customer 1
            self.cursor.execute(
                """
                INSERT INTO customer (full_name, address, phone_number, nic, dob, created_by, updated_by)
                VALUES (%s, %s, %s, %s, %s, %s, %s)
                RETURNING customer_id
                """,
                (
                    customer1_data['full_name'],
                    customer1_data.get('address'),
                    customer1_data.get('phone_number'),
                    customer1_data['nic'],
                    customer1_data['dob'],
                    created_by_user_id,
                    created_by_user_id
                )
            )
            customer1_id = self.cursor.fetchone()['customer_id']

            # Insert customer 2
            self.cursor.execute(
                """
                INSERT INTO customer (full_name, address, phone_number, nic, dob, created_by, updated_by)
                VALUES (%s, %s, %s, %s, %s, %s, %s)
                RETURNING customer_id
                """,
                (
                    customer2_data['full_name'],
                    customer2_data.get('address'),
                    customer2_data.get('phone_number'),
                    customer2_data['nic'],
                    customer2_data['dob'],
                    created_by_user_id,
                    created_by_user_id
                )
            )
            customer2_id = self.cursor.fetchone()['customer_id']

            # Auto-create logins using generated username and password
            username1 = self._generate_username(customer1_data['full_name'])
            password1 = self._generate_password()
            username2 = self._generate_username(customer2_data['full_name'])
            password2 = self._generate_password()
            hashed_password1 = hash_password(password1)
            hashed_password2 = hash_password(password2)
            
            self.cursor.execute(
                """
                INSERT INTO customer_login (customer_id, username, password, created_by, updated_by)
                VALUES (%s, %s, %s, %s, %s)
                """,
                (customer1_id, username1, hashed_password1, created_by_user_id, created_by_user_id)
            )
            self.cursor.execute(
                """
                INSERT INTO customer_login (customer_id, username, password, created_by, updated_by)
                VALUES (%s, %s, %s, %s, %s)
                """,
                (customer2_id, username2, hashed_password2, created_by_user_id, created_by_user_id)
            )

            # Get branch of the user creating the account
            self.cursor.execute("SELECT branch_id FROM users_branch WHERE user_id = %s", (created_by_user_id,))
            branch_row = self.cursor.fetchone()
            if not branch_row:
                self.conn.rollback()
                return None
            branch_id = branch_row['branch_id']

            # Create joint account
            self.cursor.execute(
                """
                INSERT INTO account (branch_id, savings_plan_id, balance, status, created_by, updated_by)
                VALUES (%s, %s, %s, %s, %s, %s)
                RETURNING acc_id, account_no
                """,
                (
                    branch_id,
                    account_data['savings_plan_id'],
                    account_data.get('balance', 0.0),
                    'active',
                    created_by_user_id,
                    created_by_user_id
                )
            )
            acc_row = self.cursor.fetchone()
            acc_id = acc_row['acc_id']
            account_no = acc_row['account_no']

            # Link both customers as owners
            self.cursor.execute(
                "INSERT INTO accounts_owner (acc_id, customer_id) VALUES (%s, %s), (%s, %s)",
                (acc_id, customer1_id, acc_id, customer2_id)
            )
            self.conn.commit()
            return {
                "customer1": {
                    "customer_id": customer1_id,
                    "nic": customer1_data['nic'],
                    "username": username1,
                    "password": password1
                },
                "customer2": {
                    "customer_id": customer2_id,
                    "nic": customer2_data['nic'],
                    "username": username2,
                    "password": password2
                },
                "acc_id": acc_id,
                "account_no": account_no
            }
        except Exception as e:
            self.conn.rollback()
            raise e

    def create_joint_account_with_existing_and_new_customer(self, existing_nic, new_customer_data, account_data, created_by_user_id):
        """
        Create a joint account for one existing and one new customer. Auto-create login for new customer.
        Returns: (existing_customer_id, new_customer_id, acc_id, account_no, username, password)
        """
        try:
            account_data, created_by_user_id = self._ensure_strings(account_data, created_by_user_id)

            # Get existing customer ID
            self.cursor.execute("SELECT customer_id FROM customer WHERE nic = %s", (existing_nic,))
            row = self.cursor.fetchone()
            if not row:
                return None
            existing_customer_id = row['customer_id']

            # Insert new customer
            self.cursor.execute(
                """
                INSERT INTO customer (full_name, address, phone_number, nic, dob, created_by, updated_by)
                VALUES (%s, %s, %s, %s, %s, %s, %s)
                RETURNING customer_id
                """,
                (
                    new_customer_data['full_name'],
                    new_customer_data.get('address'),
                    new_customer_data.get('phone_number'),
                    new_customer_data['nic'],
                    new_customer_data['dob'],
                    created_by_user_id,
                    created_by_user_id
                )
            )
            new_customer_id = self.cursor.fetchone()['customer_id']

            # Auto-create login for new customer
            username = self._generate_username(new_customer_data['full_name'])
            password = self._generate_password()
            hashed_password = hash_password(password)
            self.cursor.execute(
                """
                INSERT INTO customer_login (customer_id, username, password, created_by, updated_by)
                VALUES (%s, %s, %s, %s, %s)
                """,
                (new_customer_id, username, hashed_password, created_by_user_id, created_by_user_id)
            )

            # Get branch of the user creating the account
            self.cursor.execute("SELECT branch_id FROM users_branch WHERE user_id = %s", (created_by_user_id,))
            branch_row = self.cursor.fetchone()
            if not branch_row:
                self.conn.rollback()
                return None
            branch_id = branch_row['branch_id']

            # Create joint account
            self.cursor.execute(
                """
                INSERT INTO account (branch_id, savings_plan_id, balance, status, created_by, updated_by)
                VALUES (%s, %s, %s, %s, %s, %s)
                RETURNING acc_id, account_no
                """,
                (
                    branch_id,
                    account_data['savings_plan_id'],
                    account_data.get('balance', 0.0),
                    'active',
                    created_by_user_id,
                    created_by_user_id
                )
            )
            acc_row = self.cursor.fetchone()
            acc_id = acc_row['acc_id']
            account_no = acc_row['account_no']

            # Link both customers as owners
            self.cursor.execute(
                "INSERT INTO accounts_owner (acc_id, customer_id) VALUES (%s, %s), (%s, %s)",
                (acc_id, existing_customer_id, acc_id, new_customer_id)
            )
            self.conn.commit()
            return existing_customer_id, new_customer_id, acc_id, account_no, username, password
        except Exception as e:
            self.conn.rollback()
            raise e
