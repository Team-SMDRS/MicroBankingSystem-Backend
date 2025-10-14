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
        
    def close_fixed_deposit(self, fd_account_no, closed_by_user_id=None):
        """
        Close a fixed deposit account: transfer balance to linked savings account, set FD balance to 0, status to inactive.
        """
        try:
            fd = self.repo.get_fixed_deposit_by_account_number(fd_account_no)
            if not fd:
                raise HTTPException(status_code=404, detail="Fixed deposit not found")
            if getattr(fd, "status", "active") != "active":
                raise HTTPException(status_code=400, detail="FD account is not active")

            # Get linked savings account
            savings_account = self.repo.get_savings_account_by_fd_number(fd_account_no)
            if not savings_account:
                raise HTTPException(status_code=404, detail="Linked savings account not found")

            # Transfer FD balance to savings account
            transfer_success = self.repo.transfer_fd_balance_to_savings(fd_account_no, savings_account["account_no"], fd["balance"])
            if not transfer_success:
                raise HTTPException(status_code=500, detail="Failed to transfer FD balance to savings account")

            # Set FD balance to 0 and status to inactive
            updated_fd = self.repo.close_fixed_deposit(fd_account_no, closed_by_user_id)
            if not updated_fd:
                raise HTTPException(status_code=500, detail="Failed to close FD account")
            return updated_fd
        


        except HTTPException:
            raise
        except Exception as e:
            raise HTTPException(status_code=500, detail=f"Failed to close FD account: {str(e)}")

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
        """Get all fixed deposit plans (regardless of status)"""
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

    def get_fixed_deposit_by_fd_id(self, fd_id):
        """Get fixed deposit by FD ID"""
        try:
            fd = self.repo.get_fixed_deposit_by_fd_id(fd_id)
            if not fd:
                raise HTTPException(status_code=404, detail="Fixed deposit not found")
            return fd
        except HTTPException:
            raise
        except Exception as e:
            raise HTTPException(status_code=500, detail="Failed to retrieve fixed deposit")

    def get_fixed_deposits_by_savings_account(self, savings_account_no):
        """Get all fixed deposits linked to a savings account"""
        try:
            fds = self.repo.get_fixed_deposits_by_savings_account(savings_account_no)
            return fds
        except Exception as e:
            raise HTTPException(status_code=500, detail="Failed to retrieve fixed deposits")

    def get_fixed_deposits_by_customer_id(self, customer_id):
        """Get all fixed deposits for a customer"""
        try:
            fds = self.repo.get_fixed_deposits_by_customer_id(customer_id)
            return fds
        except Exception as e:
            raise HTTPException(status_code=500, detail="Failed to retrieve fixed deposits")

    def get_fixed_deposit_by_account_number(self, fd_account_no):
        """Get fixed deposit by FD account number"""
        try:
            # Always return details and message (if not matured)
            def convert_decimals(obj):
                if isinstance(obj, dict):
                    return {k: convert_decimals(v) for k, v in obj.items()}
                elif isinstance(obj, list):
                    return [convert_decimals(i) for i in obj]
                elif hasattr(obj, '__dict__'):
                    return convert_decimals(vars(obj))
                elif type(obj).__name__ == 'Decimal':
                    return float(obj)
                else:
                    return obj

            result = dict(updated_fd) if not isinstance(updated_fd, dict) else updated_fd
            result = convert_decimals(result)
            message = None
            if not matured:
                message = "Fixed Deposit is not matured. Closed before maturity date."
            return {
                "details": result,
                "message": message
            }
            fd = self.repo.get_fixed_deposit_by_account_number(fd_account_no)
            if not fd:
                raise HTTPException(status_code=404, detail="Fixed deposit not found")
            return fd
        except HTTPException:
            raise
        except Exception as e:
            raise HTTPException(status_code=500, detail="Failed to retrieve fixed deposit")

    def get_fd_plan_by_fd_id(self, fd_id):
        """Get FD plan details by FD ID"""
        try:
            plan = self.repo.get_fd_plan_by_fd_id(fd_id)
            if not plan:
                raise HTTPException(status_code=404, detail="FD plan not found for this fixed deposit")
            return plan
        except HTTPException:
            raise
        except Exception as e:
            print(e)
            raise HTTPException(status_code=500, detail="Failed to retrieve FD plan")


    def get_savings_account_by_fd_number(self, fd_account_no):
        """Get savings account details by FD account number"""
        try:
            account = self.repo.get_savings_account_by_fd_number(fd_account_no)
            if not account:
                raise HTTPException(status_code=404, detail="Savings account not found for this FD")
            return account
        except HTTPException:
            raise
        except Exception as e:
            raise HTTPException(status_code=500, detail="Failed to retrieve savings account")

    def get_owner_by_fd_number(self, fd_account_no):
        """Get customer (owner) details by FD account number"""
        try:
            owner = self.repo.get_owner_by_fd_number(fd_account_no)
            if not owner:
                raise HTTPException(status_code=404, detail="Owner not found for this FD")
            return owner
        except HTTPException:
            raise
        except Exception as e:
            raise HTTPException(status_code=500, detail="Failed to retrieve owner details")

    def close_fixed_deposit(self, fd_account_no, closed_by_user_id=None):
        """
        Close a fixed deposit account: transfer balance to linked savings account, set FD balance to 0, status to inactive.
        If account is not matured, include a message in the response.
        """
        from datetime import datetime
        try:
            fd = self.repo.get_fixed_deposit_by_account_number(fd_account_no)
            if not fd:
                raise HTTPException(status_code=404, detail="Fixed deposit not found")
            if fd.get("status", "active") != "active":
                raise HTTPException(status_code=400, detail="FD account is not active")

            # Check maturity date
            today = datetime.now().date()
            maturity_date = fd["maturity_date"].date() if hasattr(fd["maturity_date"], "date") else fd["maturity_date"]
            matured = (maturity_date <= today)

            # Get linked savings account
            savings_account = self.repo.get_savings_account_by_fd_number(fd_account_no)
            if not savings_account:
                raise HTTPException(status_code=404, detail="Linked savings account not found")

            # Transfer FD balance to savings account
            transfer_success = self.repo.transfer_fd_balance_to_savings(fd_account_no, savings_account["account_no"], fd["balance"])
            if not transfer_success:
                raise HTTPException(status_code=500, detail="Failed to transfer FD balance to savings account")

            # Set FD balance to 0 and status to inactive
            updated_fd = self.repo.close_fixed_deposit(fd_account_no, closed_by_user_id)
            if not updated_fd:
                raise HTTPException(status_code=500, detail="Failed to close FD account")

            def convert_for_json(obj):
                import datetime
                if isinstance(obj, dict):
                    return {k: convert_for_json(v) for k, v in obj.items()}
                elif isinstance(obj, list):
                    return [convert_for_json(i) for i in obj]
                elif type(obj).__name__ == 'Decimal':
                    return float(obj)
                elif isinstance(obj, datetime.datetime) or isinstance(obj, datetime.date):
                    return obj.isoformat()
                else:
                    return obj

            result = dict(updated_fd) if not isinstance(updated_fd, dict) else updated_fd
            result = convert_for_json(result)
            message = None
            if not matured:
                message = "Account is not matured. Closed before maturity date."
            return {
                "details": result,
                "message": message
            }
        except HTTPException:
            raise
        except Exception as e:
            raise HTTPException(status_code=500, detail=f"Failed to close FD account: {str(e)}")

    def get_fixed_deposits_by_status(self, status):
        """Get all fixed deposits by status"""
        try:
            fds = self.repo.get_fixed_deposits_by_status(status)
            return fds
        except Exception as e:
            raise HTTPException(status_code=500, detail="Failed to retrieve fixed deposits by status")

    def get_matured_fixed_deposits(self):
        """Get all matured fixed deposits"""
        try:
            fds = self.repo.get_matured_fixed_deposits()
            return fds
        except Exception as e:
            raise HTTPException(status_code=500, detail="Failed to retrieve matured fixed deposits")

    def get_fixed_deposits_by_plan_id(self, fd_plan_id):
        """Get all fixed deposit accounts for a given FD plan ID"""
        try:
            fds = self.repo.get_fixed_deposits_by_plan_id(fd_plan_id)
            return fds
        except Exception as e:
            raise HTTPException(status_code=500, detail="Failed to retrieve fixed deposits for the given plan")



