from psycopg2.extras import RealDictCursor

class SavingsPlanRepository:

    def __init__(self, db_conn):
        self.conn = db_conn
        self.cursor = self.conn.cursor(cursor_factory=RealDictCursor)

    def create_savings_plan(self, plan_data):
        """
        Create a new savings plan using the SQL function.
        Checks for duplicate plan name before creation.
        plan_data: dict with keys 'plan_name', 'interest_rate', 'user_id'
        Returns: savings_plan_id of the new plan or None if duplicate
        """
        # Check if a plan with the same name already exists
        self.cursor.execute(
            """
            SELECT 1 FROM savings_plan WHERE plan_name = %s
            """,
            (plan_data['plan_name'],)
        )
        if self.cursor.fetchone():
            return None  # Duplicate found

        self.cursor.execute(
            """
            SELECT * FROM create_savings_plan(%s, %s, %s,%s)
            """,
            (
                plan_data['plan_name'],
                plan_data['interest_rate'],
                plan_data['user_id'],
                # support both old and new field names just in case
                plan_data.get('minimum_balance', plan_data.get('min_balance', 0))
            )
        )
        row = self.cursor.fetchone()
        self.conn.commit()
        return row['savings_plan_id'] if row else None
    
    def update_savings_plan(self, savings_plan_id, new_interest_rate, user_id):
        """
        Update the interest rate of a savings plan and set updated_by to the current user.
        Args:
            savings_plan_id: UUID of the savings plan to update
            new_interest_rate: new interest rate (float)
            user_id: UUID of the user making the update (should be set automatically by the service/API)
        Returns: updated savings plan row or None if not found
        """
        self.cursor.execute(
            """
            UPDATE savings_plan
            SET interest_rate = %s, updated_by = %s, updated_at = CURRENT_TIMESTAMP
            WHERE savings_plan_id = %s
            RETURNING *
            """,
            (new_interest_rate, user_id, savings_plan_id)
        )
        row = self.cursor.fetchone()
        self.conn.commit()
        return row
    
    def get_all_savings_plans(self):
        """
        Return all savings plans with their ids and names.
        Returns: list of dicts with keys 'savings_plan_id' and 'plan_name'
        """
        self.cursor.execute(
            """
            SELECT savings_plan_id, plan_name
            FROM savings_plan
            ORDER BY plan_name
            """
        )
        rows = self.cursor.fetchall()
        return rows

    def get_all_savings_plan_details(self):
        """
        Return all savings plans with id, name, interest rate and minimum balance.
        Returns: list of dicts with keys 'savings_plan_id', 'plan_name', 'interest_rate', 'minimum_balance'
        """
        self.cursor.execute(
            """
            SELECT savings_plan_id, plan_name, interest_rate, COALESCE(minimum_balance, 0) AS minimum_balance
            FROM savings_plan
            ORDER BY plan_name
            """
        )
        rows = self.cursor.fetchall()
        return rows