    
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
    
   

 

  


   
