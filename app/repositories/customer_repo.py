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
    
   

 

  


   
