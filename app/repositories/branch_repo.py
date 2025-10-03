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
        Update branch details by branch ID.
        Only allows updating name and address.
        updated_at is automatically handled by the DB trigger.
        updated_by is set to current_user_id.
        """
        allowed_fields = {"name", "address"}
        fields = []
        values = []

        for key, value in update_data.items():
            if key in allowed_fields and value is not None:
                fields.append(f"{key} = %s")
                values.append(value)

        if not fields:
            return None  # nothing to update

        # updated_by must be set manually
        fields.append("updated_by = %s")
        values.append(current_user_id)

        set_clause = ", ".join(fields)

        query = f"""
                UPDATE branch
                SET {set_clause}
                WHERE branch_id = %s
                RETURNING branch_id, name, address, created_at, updated_at, created_by, updated_by
            """
        values.append(branch_id)

        self.cursor.execute(query, tuple(values))
        self.conn.commit()

        result = self.cursor.fetchone()
        return dict(result) if result else None
