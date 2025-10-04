# Branch repository - Database operations for branches

from psycopg2.extras import RealDictCursor


class BranchRepository:
    def __init__(self, db_conn):
        self.conn = db_conn
        self.cursor = self.conn.cursor(cursor_factory=RealDictCursor)

    def get_all_branches(self):
        """
        Fetch all branches from the database.
        """
        self.cursor.execute(
            """SELECT 
                branch_id,
                name,
                address,
                created_at
 
            FROM branch 
            ORDER BY name ASC"""
        )
        return self.cursor.fetchall()

    def get_branch_by_id(self, branch_id):
        """
        Fetch a branch by its ID.
        """
        self.cursor.execute(
            """SELECT *
            FROM branch 
            WHERE branch_id = %s""",
            (branch_id,)
        )
        return self.cursor.fetchall()

    def get_branch_by_name(self, branch_name):
        """
        Fetch a branch by its name.
        """
        self.cursor.execute(
            """SELECT *
            FROM branch 
            WHERE name ILIKE %s""",
            (f"%{branch_name}%",)
        )
        return self.cursor.fetchall()

    def update_branch(self, branch_id, update_data, current_user_id):
        """
        Update branch details by branch ID using database function.
        Only allows updating name and address.
        """
        try:
            # Extract only allowed fields
            name = update_data.get('name')
            address = update_data.get('address')
            
            # Check if there are any updates to make
            if name is None and address is None:
                return None
            
            self.cursor.execute(
                """
                SELECT * FROM update_branch(%s, %s, %s, %s)
                """,
                (
                    branch_id,
                    name,
                    address,
                    str(current_user_id)
                )
            )
            
            result = self.cursor.fetchone()
            self.conn.commit()
            return dict(result) if result else None
            
        except Exception as e:
            self.conn.rollback()
            # Handle database function exceptions
            error_message = str(e)
            if "not found" in error_message:
                raise Exception("Branch not found")
            elif "already exists" in error_message:
                raise Exception(error_message)
            elif "No valid fields to update" in error_message:
                raise Exception("No valid fields to update")
            else:
                raise e

    def create_branch(self, branch_data, created_by):
        """
        Create a new branch using database function.
        """
        try:
            self.cursor.execute(
                """
                SELECT * FROM create_branch(%s, %s, %s)
                """,
                (
                    branch_data.name,
                    branch_data.address,
                    str(created_by)
                )
            )
            branch = self.cursor.fetchone()
            self.conn.commit()
            return dict(branch) if branch else None
        except Exception as e:
            self.conn.rollback()
            # Handle database function exceptions
            if "already exists" in str(e):
                raise Exception("Branch with this name already exists")
            elif "cannot be empty" in str(e):
                raise Exception(str(e))
            else:
                raise e
