	
from fastapi import HTTPException
from uuid import UUID
from app.repositories.joint_account_management_repo import JointAccountManagementRepository
from app.repositories.account_management_repo import AccountManagementRepository

class JointAccountManagementService:

    def __init__(self, db_conn):
        self.repo = JointAccountManagementRepository(db_conn)
        self.account_repo = AccountManagementRepository(db_conn)

    def _get_joint_account_plan_id(self):
        """Get the savings plan ID for joint accounts"""
        try:
            return self.repo.get_joint_account_plan_id("Joint")
        except Exception as e:
            raise HTTPException(status_code=500, detail=f"Failed to get joint account plan ID: {str(e)}")

    def _validate_user_authentication(self, user_id):
        """Validate user authentication and return stringified UUID."""
        if not user_id:
            raise HTTPException(status_code=401, detail="User not authenticated")
        try:
            user_uuid = UUID(str(user_id))
            return str(user_uuid)
        except Exception:
            raise HTTPException(status_code=400, detail="user_id must be a valid UUID string")

    def _normalize_account_data(self, account_data: dict) -> dict:
        """Set savings_plan_id automatically and ensure all values are strings for psycopg2."""
        if not isinstance(account_data, dict):
            return account_data
        
        # Always set the joint account savings plan ID - don't accept from user
        account_data["savings_plan_id"] = self._get_joint_account_plan_id()
        
        # Ensure all values are strings for psycopg2
        for key, value in account_data.items():
            if value is not None:
                account_data[key] = str(value)
        
        return account_data

    def create_joint_account(self, account_data, nic1, nic2, user_id):
        """Create joint account with existing customers (validations + normalization)."""
        validated_user_id = self._validate_user_authentication(user_id)
        account_data = self._normalize_account_data(account_data)

        # Validate savings plan minimum balance
        try:
            min_balance = self.account_repo.get_minimum_balance_by_savings_plan_id(account_data["savings_plan_id"])
        except Exception:
            raise HTTPException(status_code=500, detail="Failed to validate savings plan")

        if min_balance is None:
            raise HTTPException(status_code=400, detail="Invalid savings plan ID")

        try:
            min_balance_val = float(min_balance)
        except Exception:
            raise HTTPException(status_code=500, detail="Invalid minimum balance configured for savings plan")

        # Get balance from account_data
        balance = account_data.get("balance", "0")
        if float(balance) < min_balance_val:
            raise HTTPException(status_code=400, detail=f"Initial balance must be at least {min_balance_val} for the selected savings plan")
        
        # Validate savings plan name
        savings_plan_name = self.account_repo.get_plan_name_by_savings_plan_id(account_data["savings_plan_id"])
        if savings_plan_name != "Joint":
            raise HTTPException(status_code=400, detail="Cannot create other account using this endpoint. Please use the create account creation endpoint.")

        try:
            result = self.repo.create_joint_account(account_data, nic1, nic2, validated_user_id)
        except Exception as e:
            raise HTTPException(status_code=500, detail=str(e))

        if not result:
            raise HTTPException(status_code=404, detail="One or both customers not found")

        return result

    def create_joint_account_with_new_customers(self, customer1_data, customer2_data, account_data, user_id):
        """Create joint account with two new customers (validations + normalization)."""
        validated_user_id = self._validate_user_authentication(user_id)
        account_data = self._normalize_account_data(account_data)

        # Validate savings plan minimum balance
        try:
            min_balance = self.account_repo.get_minimum_balance_by_savings_plan_id(account_data["savings_plan_id"])
        except Exception:
            raise HTTPException(status_code=500, detail="Failed to validate savings plan")

        if min_balance is None:
            raise HTTPException(status_code=400, detail="Invalid savings plan ID")

        try:
            min_balance_val = float(min_balance)
        except Exception:
            raise HTTPException(status_code=500, detail="Invalid minimum balance configured for savings plan")

        # Get balance from account_data
        balance = account_data.get("balance", "0")
        if float(balance) < min_balance_val:
            raise HTTPException(status_code=400, detail=f"Initial balance must be at least {min_balance_val} for the selected savings plan")
        
        # Validate savings plan name
        savings_plan_name = self.account_repo.get_plan_name_by_savings_plan_id(account_data["savings_plan_id"])
        if savings_plan_name != "Joint":
            raise HTTPException(status_code=400, detail="Cannot create other account using this endpoint. Please use the create account creation endpoint.")

        try:
            result = self.repo.create_joint_account_with_new_customers(
                customer1_data, customer2_data, account_data, validated_user_id
            )
        except Exception as e:
            raise HTTPException(status_code=500, detail=str(e))

        if not result:
            raise HTTPException(status_code=400, detail="Could not create joint account for new customers")

        return result

    def create_joint_account_with_existing_and_new_customer(self, existing_nic, new_customer_data, account_data, user_id):
        """Create joint account with one existing and one new customer (validations + normalization)."""
        validated_user_id = self._validate_user_authentication(user_id)
        account_data = self._normalize_account_data(account_data)

        # Validate savings plan minimum balance
        try:
            min_balance = self.account_repo.get_minimum_balance_by_savings_plan_id(account_data["savings_plan_id"])
        except Exception:
            raise HTTPException(status_code=500, detail="Failed to validate savings plan")

        if min_balance is None:
            raise HTTPException(status_code=400, detail="Invalid savings plan ID")

        try:
            min_balance_val = float(min_balance)
        except Exception:
            raise HTTPException(status_code=500, detail="Invalid minimum balance configured for savings plan")

        # Get balance from account_data
        balance = account_data.get("balance", "0")
        if float(balance) < min_balance_val:
            raise HTTPException(status_code=400, detail=f"Initial balance must be at least {min_balance_val} for the selected savings plan")
        
        # Validate savings plan name
        savings_plan_name = self.account_repo.get_plan_name_by_savings_plan_id(account_data["savings_plan_id"])
        if savings_plan_name != "Joint":
            raise HTTPException(status_code=400, detail="Cannot create other account using this endpoint. Please use the create account creation endpoint.")

        try:
            result = self.repo.create_joint_account_with_existing_and_new_customer(
                existing_nic, new_customer_data, account_data, validated_user_id
            )
        except Exception as e:
            raise HTTPException(status_code=500, detail=str(e))

        if not result:
            raise HTTPException(status_code=400, detail="Could not create joint account for existing and new customer")

        return result