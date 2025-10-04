class SavingsPlanService:

    def __init__(self, repo):
        self.repo = repo


    def create_savings_plan(self, plan_data):
        """
        Create a new savings plan. Returns dict with result or error.
        """
        filtered = {k: plan_data[k] for k in ('plan_name', 'interest_rate', 'user_id') if k in plan_data}
        
        # Validate interest rate
        if 'interest_rate' in filtered and filtered['interest_rate'] >= 100:
            return {"error": "Interest rate must be less than 100."}
        
        savings_plan_id = self.repo.create_savings_plan(filtered)
        if savings_plan_id is None:
            return {"error": "A savings plan with this name already exists."}
        return {"savings_plan_id": savings_plan_id}
    
    def update_savings_plan(self, savings_plan_id, new_interest_rate, user_id):
        """
        Update the interest rate of a savings plan and set updated_by to the current user.
        """
        # Validate interest rate
        if new_interest_rate >= 100:
            return {"error": "Interest rate must be less than 100."}
        
        result = self.repo.update_savings_plan(savings_plan_id, new_interest_rate, user_id)
        if result is None:
            return {"error": "Failed to update savings plan."}
        return {"success": True}