#user repo .py
from psycopg2.extras import RealDictCursor

class UserRepository:
    def __init__(self, db_conn):

        self.conn = db_conn
        self.cursor = self.conn.cursor(cursor_factory=RealDictCursor)

    def create_user(self, user_data, hashed_password: str):
        """
        Calls the PostgreSQL function `create_user` to insert into
        `users` and `login` automatically.
        Returns the new user_id.
        """
        self.cursor.execute(
            """
            SELECT create_user(%s, %s, %s, %s, %s, %s, %s)
            """,
            (
                user_data.nic,
                user_data.first_name,
                user_data.last_name,
                user_data.address,
                user_data.phone_number,
                user_data.username,
                hashed_password,
            )
        )
        row = self.cursor.fetchone()
        self.conn.commit()
        
        # Access by column name because of RealDictCursor
        user_id = row['create_user'] if row else None
        return user_id


    def get_login_by_username(self, username: str):
        """
        Fetch a login row by username.
        """
        self.cursor.execute(
            "SELECT * FROM user_login WHERE username = %s",
            (username,)
        )
        return self.cursor.fetchone()
    
    def update_login_success (self,user_id):
        self.cursor.execute(
           "INSERT INTO login (user_id) VALUES (%s)",
            (user_id,)
        )
        self.conn.commit()

    def insert_login_time (self,user_id):
        self.cursor.execute(
           "INSERT INTO login (user_id) VALUES (%s)",
            (user_id,)
        )
        self.conn.commit()

    def get_user_permissions(self, user_id):
        self.cursor.execute(
            """
            SELECT p.permission_name
            FROM users_permission up
            JOIN permission p ON up.permission_id = p.permission_id
            WHERE up.user_id = %s
            """,
            (user_id,)
        )
        rows = self.cursor.fetchall()
        # Since you're using RealDictCursor, access by column name
        return [row["permission_name"] for row in rows]
