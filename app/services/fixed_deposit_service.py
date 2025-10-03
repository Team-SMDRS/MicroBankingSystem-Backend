# Fixed Deposit service - Business logic for fixed deposit operations

from fastapi import HTTPException

class FixedDepositService:
    def __init__(self, repo):
        self.repo = repo

    def get_all_fixed_deposits(self):
        """Get all fixed deposit accounts from the database"""
        try:
            fixed_deposits = self.repo.get_all_fixed_deposits()
            return fixed_deposits
        except Exception as e:
            raise HTTPException(status_code=500, detail="Failed to retrieve fixed deposits")

    def create_fd_plan(self, duration_months, interest_rate, created_by_user_id=None):
        """
        Create a new fixed deposit plan.
        """
        try:
            # Validate input parameters
            if duration_months <= 0:
                raise HTTPException(status_code=400, detail="Duration must be greater than 0")
            
            if interest_rate <= 0 or interest_rate > 100:
                raise HTTPException(status_code=400, detail="Interest rate must be between 0 and 100")
            
            # Create the FD plan in the database
            fd_plan = self.repo.create_fd_plan(duration_months, interest_rate, created_by_user_id)
            
            if not fd_plan:
                raise HTTPException(status_code=500, detail="Failed to create FD plan")
            
            return {
                "message": "FD plan created successfully",
                "fd_plan": fd_plan
            }
            
        except HTTPException:
            raise
        except Exception as e:
            raise HTTPException(status_code=500, detail=f"Failed to create FD plan: {str(e)}")

    def get_all_fd_plans(self):
        """Get all active fixed deposit plans"""
        try:
            fd_plans = self.repo.get_all_fd_plans()
            return fd_plans
        except Exception as e:
            raise HTTPException(status_code=500, detail="Failed to retrieve FD plans")

    def update_fd_plan_status(self, fd_plan_id, status, updated_by_user_id=None):
        """
        Update the status of an FD plan.
        Only allows updating the status field.
        """
        try:
            # Validate status value
            valid_statuses = ['active', 'inactive']
            if status not in valid_statuses:
                raise HTTPException(
                    status_code=400, 
                    detail=f"Invalid status. Must be one of: {', '.join(valid_statuses)}"
                )
            
            # Check if FD plan exists
            existing_plan = self.repo.get_fd_plan_by_id(fd_plan_id)
            if not existing_plan:
                raise HTTPException(
                    status_code=404, 
                    detail="FD plan not found"
                )
            
            # Update the status
            updated_plan = self.repo.update_fd_plan_status(fd_plan_id, status, updated_by_user_id)
            
            if not updated_plan:
                raise HTTPException(status_code=500, detail="Failed to update FD plan status")
            
            return updated_plan
            
        except HTTPException:
            raise
        except Exception as e:
            raise HTTPException(status_code=500, detail=f"Failed to update FD plan status: {str(e)}")

    def create_fixed_deposit(self, savings_account_no, amount, plan_id, created_by_user_id=None):
        """
        Create a new fixed deposit account.
        Requires customer to have an active savings account.
        """
        try:
            # Validate input parameters
            if amount <= 0:
                raise HTTPException(status_code=400, detail="Amount must be greater than 0")
            
            # Validate and get savings account (customer must have a savings account)
            savings_account = self.repo.get_savings_account_by_account_no(savings_account_no)
            if not savings_account:
                raise HTTPException(
                    status_code=404, 
                    detail="Savings account not found or inactive"
                )
            
            # Validate FD plan
            fd_plan = self.repo.validate_fd_plan(plan_id)
            if not fd_plan:
                raise HTTPException(
                    status_code=404, 
                    detail="FD plan not found or inactive"
                )
            
            # Create the fixed deposit (no deduction from savings account)
            fixed_deposit = self.repo.create_fixed_deposit(
                savings_account['acc_id'], 
                amount, 
                plan_id,
                created_by_user_id
            )
            
            if not fixed_deposit:
                raise HTTPException(status_code=500, detail="Failed to create fixed deposit")
            
            # Get complete fixed deposit details for response
            fd_details = self.repo.get_fixed_deposit_with_details(fixed_deposit['fd_id'])
            
            return fd_details
            
        except HTTPException:
            raise
        except Exception as e:
            raise HTTPException(status_code=500, detail=f"Failed to create fixed deposit: {str(e)}")



