#customer branch repo .py


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
   

 

  


   
