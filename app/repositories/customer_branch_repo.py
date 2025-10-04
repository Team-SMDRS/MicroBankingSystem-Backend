# Customer branch repository


from psycopg2.extras import RealDictCursor


class CustomerBranchRepository:
    def __init__(self, db_conn):
        self.conn = db_conn
        self.cursor = self.conn.cursor(cursor_factory=RealDictCursor)

    def get_all_customers(self):
        """
        Fetch all customers.
        """
        self.cursor.execute(
            "SELECT customer_id, full_name, nic FROM customer",
        )
        return self.cursor.fetchall()

    def get_customers_by_users_branch(self, branch_id: str):
        """
        Fetch customers by branch ID.
        """
        self.cursor.execute(
            "SELECT c.customer_id, c.full_name, c.nic FROM customer as c left join Accounts_owner on c.customer_id = Accounts_owner.customer_id left join account on Accounts_owner.acc_id = account.acc_id WHERE branch_id = %s",
            (branch_id,)
        )
        return self.cursor.fetchall()

    def get_customers_count(self):
        """
        Fetch total customer count.
        """
        self.cursor.execute("SELECT COUNT(*) AS count FROM customer")
        result = self.cursor.fetchone()
        return result["count"] if result else 0

    def get_customers_count_by_branch(self, branch_id: str):
        self.cursor.execute(
            """
            SELECT COUNT(DISTINCT c.customer_id) AS count
            FROM customer AS c
            LEFT JOIN Accounts_owner ao ON c.customer_id = ao.customer_id
            LEFT JOIN account a ON ao.acc_id = a.acc_id
            WHERE a.branch_id = %s
            """,
            (branch_id,)
        )
        result = self.cursor.fetchone()
        return result["count"] if result else 0

    # def get_customers_count_by_branch_id(self, branch_id: str):
    #     self.cursor.execute(
    #         """
    #         SELECT COUNT(DISTINCT c.customer_id) AS count
    #         FROM customer AS c
    #         LEFT JOIN Accounts_owner ao ON c.customer_id = ao.customer_id
    #         LEFT JOIN account a ON ao.acc_id = a.acc_id
    #         WHERE a.branch_id = %s
    #         """,
    #         (branch_id,)
    #     )
    #     result = self.cursor.fetchone()
    #     return result["count"] if result else 0

    # get all customers by branch id
    def get_customers_by_branch_id(self, branch_id: str):
        """
        Fetch customers by branch ID.
        """
        self.cursor.execute(
            """
            SELECT DISTINCT c.customer_id, c.full_name, c.nic, c.address, c.phone_number          
            FROM customer c
            JOIN Accounts_owner ao ON c.customer_id = ao.customer_id
            JOIN account a ON ao.acc_id = a.acc_id
            WHERE a.branch_id = %s;

            """,
            (branch_id,)
        )
        return self.cursor.fetchall()

    def get_accounts_count_by_branch_id(self, branch_id: str):
        self.cursor.execute(
            """
            SELECT COUNT(*) AS count
            FROM account
            WHERE branch_id = %s
            """,
            (branch_id,)
        )
        result = self.cursor.fetchone()
        return result["count"] if result else 0

    def get_total_balance_by_branch_id(self, branch_id: str):
        self.cursor.execute(
            """
            SELECT SUM(balance) AS total_balance
            FROM account
            WHERE branch_id = %s
            """,
            (branch_id,)
        )
        result = self.cursor.fetchone()
        return result["total_balance"] if result else 0
