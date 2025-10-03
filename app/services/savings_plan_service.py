class SavingsPlanService:

    def __init__(self, repo):
        self.repo = repo


    def create_savings_plan(self, plan_data):
        """
        Create a new savings plan. Returns dict with result or error.
        """
        filtered = {k: plan_data[k] for k in ('plan_name', 'interest_rate', 'user_id') if k in plan_data}
        savings_plan_id = self.repo.create_savings_plan(filtered)
        if savings_plan_id is None:
            return {"error": "A savings plan with this name already exists."}
        return {"savings_plan_id": savings_plan_id}
    
    def update_savings_plan(self, savings_plan_id, new_interest_rate, user_id):
        """
        Update the interest rate of a savings plan and set updated_by to the current user.
        """
        return self.repo.update_savings_plan(savings_plan_id, new_interest_rate, user_id)