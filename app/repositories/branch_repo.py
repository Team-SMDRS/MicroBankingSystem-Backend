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
            """SELECT 
                branch_id,
                name,
                address,
                created_at
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
            """SELECT 
                branch_id,
                name,
                address,
                created_at
            FROM branch 
            WHERE name ILIKE %s""",
            (f"%{branch_name}%",)
        )
        return self.cursor.fetchall()
    
