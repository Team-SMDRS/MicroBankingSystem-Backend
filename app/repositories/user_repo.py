#user repo .py


from psycopg2.extras import RealDictCursor

class UserRepository:
    def __init__(self, db_conn):
        self.conn = db_conn
        self.cursor = self.conn.cursor(cursor_factory=RealDictCursor)


    def get_user_branch_id(self, user_id):
        self.cursor.execute(
            "SELECT branch_id FROM users_branch WHERE user_id = %s",
            (user_id,)
        )
        row = self.cursor.fetchone()
        return row['branch_id'] if row else None
    def __init__(self, db_conn):
        self.conn = db_conn
        self.cursor = self.conn.cursor(cursor_factory=RealDictCursor)

    def create_user(self, user_data, hashed_password: str, created_by_user_id: str):
      
        """
        Calls the PostgreSQL function `create_user` to insert a new user
        and their login information. Returns the new user_id.
        """
        try:
            self.cursor.execute(
                """
                SELECT create_user(%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                """,
                (
                    user_data.nic,
                    user_data.first_name,
                    user_data.last_name,
                    user_data.address,
                    user_data.phone_number,
                    user_data.dob,
                    user_data.username,
                    hashed_password,
                    created_by_user_id,
                    created_by_user_id
                    
                    
                    
                )
            )

            row = self.cursor.fetchone()
            if row is None:
                raise Exception("User creation failed: no row returned from DB.")

            user_id = row.get('create_user')
            if not user_id:
                raise Exception("User creation failed: returned row does not contain user_id.")

            self.conn.commit()
            return user_id

        except Exception as e:
            self.conn.rollback()
            raise Exception(f"Error in create_user: {e}")


    def get_login_by_username(self, username: str):
        """
        Fetch a login row by username.
        """
        self.cursor.execute(
            "SELECT * FROM user_login WHERE username = %s",
            (username,)
        )
        return self.cursor.fetchone()

    def insert_login_time(self, user_id, ip_address, device_info):
        """Log user login activity"""
        self.cursor.execute(
           "INSERT INTO login (user_id, ip_address, device_info) VALUES (%s, %s, %s)",
            (user_id, ip_address, device_info)
        )
        self.conn.commit()

    def get_user_permissions(self, user_id):
        self.cursor.execute(
            """
            SELECT r.role_name
            FROM users_role ur
            JOIN role r ON ur.role_id = r.role_id
            WHERE ur.user_id = %s
            """,
            (user_id,)
        )
        rows = self.cursor.fetchall()
        # Since you're using RealDictCursor, access by column name
        return [row["role_name"] for row in rows]

    def get_user_by_id(self, user_id):
        """Get user details by user_id"""
        self.cursor.execute(
            """
            SELECT u.*, ul.username 
            FROM users u
            JOIN user_login ul ON u.user_id = ul.user_id
            WHERE u.user_id = %s
            """,
            (user_id,)
        )
        return self.cursor.fetchone()

    # Refresh Token Methods
    def store_refresh_token(self, user_id, token_hash, expires_at, device_info=None, ip_address=None):
        """Store refresh token in database"""
        self.cursor.execute(
            """
            INSERT INTO user_refresh_tokens (
                user_id, token_hash, expires_at, device_info, ip_address
            ) VALUES (%s, %s, %s, %s, %s)
            RETURNING token_id
            """,
            (user_id, token_hash, expires_at, device_info, ip_address)
        )
        result = self.cursor.fetchone()
        self.conn.commit()
        return result['token_id'] if result else None

    def get_refresh_token(self, token_hash):
        """Get refresh token details by hash"""
        self.cursor.execute(
            """
            SELECT rt.*, ul.user_id
            FROM user_refresh_tokens rt
            JOIN user_login ul ON rt.user_id = ul.user_id
            WHERE rt.token_hash = %s 
            AND rt.is_revoked = FALSE 
            AND rt.expires_at > CURRENT_TIMESTAMP
            """,
            (token_hash,)
        )
        return self.cursor.fetchone()

    def revoke_refresh_token(self, token_hash, revoked_by_user_id):
        """Revoke a specific refresh token"""
        self.cursor.execute(
            """
            UPDATE user_refresh_tokens 
            SET is_revoked = TRUE, 
                revoked_at = CURRENT_TIMESTAMP,
                revoked_by = %s
            WHERE token_hash = %s
            """,
            (revoked_by_user_id, token_hash)
        )
        self.conn.commit()
        return self.cursor.rowcount > 0

    def revoke_all_user_tokens(self, user_id, revoked_by_user_id):
        """Revoke all refresh tokens for a user"""
        self.cursor.execute(
            """
            UPDATE user_refresh_tokens 
            SET is_revoked = TRUE, 
                revoked_at = CURRENT_TIMESTAMP,
                revoked_by = %s
            WHERE user_id = %s AND is_revoked = FALSE
            """,
            (revoked_by_user_id, user_id)
        )
        self.conn.commit()
        return self.cursor.rowcount

    def cleanup_expired_tokens(self):
        """Remove expired refresh tokens"""
        self.cursor.execute("SELECT cleanup_expired_user_refresh_tokens()")
        result = self.cursor.fetchone()
        self.conn.commit()
        return result[0] if result else 0

    def get_user_active_tokens(self, user_id):
        """Get all active refresh tokens for a user"""
        self.cursor.execute(
            """
            SELECT token_id, device_info, ip_address, created_at, expires_at
            FROM user_refresh_tokens
            WHERE user_id = %s AND is_revoked = FALSE AND expires_at > CURRENT_TIMESTAMP
            ORDER BY created_at DESC
            """,
            (user_id,)
        )
        return self.cursor.fetchall()

    def get_user_roles(self, user_id: str):
        """Get all roles for a specific user"""
        self.cursor.execute("""
            SELECT r.role_id, r.role_name 
            FROM role r
            JOIN users_role ur ON r.role_id = ur.role_id
            WHERE ur.user_id = %s
        """, (user_id,))
        return self.cursor.fetchall()

    def get_all_users(self):
        """Get all users"""
        self.cursor.execute("""
            SELECT user_id, nic, first_name, last_name, address, 
                   phone_number, dob, email, created_at
            FROM users
            ORDER BY first_name, last_name
        """)
        return self.cursor.fetchall()

    def get_all_roles(self):
        """Get all available roles"""
        self.cursor.execute("""
            SELECT role_id, role_name 
            FROM role
            ORDER BY role_name
        """)
        return self.cursor.fetchall()

    def assign_user_roles(self, user_id: str, role_ids: list):
        """Assign roles to a user (replaces existing roles)"""
        try:
            # First, remove existing roles
            self.cursor.execute("""
                DELETE FROM users_role WHERE user_id = %s
            """, (user_id,))
            
            # Then add new roles
            for role_id in role_ids:
                self.cursor.execute("""
                    INSERT INTO users_role (user_id, role_id)
                    VALUES (%s, %s)
                """, (user_id, role_id))
            
            self.conn.commit()
            return True
        except Exception as e:
            self.conn.rollback()
            raise e

    def get_users_with_roles(self):
        """Get all users with their roles"""
        self.cursor.execute("""
            SELECT u.user_id, u.nic, u.first_name, u.last_name, u.address,
                   u.phone_number, u.dob, u.email, u.created_at,
                   r.role_id, r.role_name
            FROM users u
            LEFT JOIN users_role ur ON u.user_id = ur.user_id
            LEFT JOIN role r ON ur.role_id = r.role_id
            ORDER BY u.first_name, u.last_name
        """)
        return self.cursor.fetchall()

    def user_exists(self, user_id: str):
        """Check if user exists"""
        self.cursor.execute("""
            SELECT 1 FROM users WHERE user_id = %s
        """, (user_id,))
        return self.cursor.fetchone() is not None
