import random

import string
from fastapi import HTTPException
from app.schemas.account_management_schema import CustomerAccountInput, CustomerCreate, CustomerLoginCreate, AccountCreate, RegisterCustomerWithAccount


class AccountManagementService:
    
    
    
    def __init__(self, repo):
        self.repo = repo

    def _generate_username(self, full_name):
        # Simple username generator: first part of name + random digits
        base = ''.join(full_name.lower().split())
        suffix = ''.join(random.choices(string.digits, k=4))
        return f"{base}{suffix}"

    def _generate_password(self, length=8):
        # Simple random password generator
        chars = string.ascii_letters + string.digits
        return ''.join(random.choices(chars, k=length))


    def register_customer_with_account_minimal(self, input_data: CustomerAccountInput, created_by_user_id, branch_id):
        # Auto-generate username, password, account_no
        username = self._generate_username(input_data.full_name)
        password = self._generate_password()
     

        customer = CustomerCreate(
            full_name=input_data.full_name,
            address=input_data.address,
            phone_number=input_data.phone_number,
            nic=input_data.nic,
            dob=input_data.dob
        )
        login = CustomerLoginCreate(
            username=username,
            password=password  # In production, hash this!
        )
        account = AccountCreate(
          
            branch_id=branch_id,
            savings_plan_id=input_data.savings_plan_id,
            balance=input_data.balance,
            status=input_data.status if hasattr(input_data, 'status') else 'active'
        )
        # Call the existing repo logic
        try:
            customer_id, account_no = self.repo.create_customer_with_login(
            customer.dict(), login.dict(), created_by_user_id, account.dict()
            )
        except Exception as e:
            raise HTTPException(status_code=500, detail=f"Error creating customer/account , May be NIC or Username already exists.")
        # acc_id = self.repo.create_account_for_customer(account.dict(), customer_id, created_by_user_id)
        return {
            "msg": "Customer registered and account created",
            "customer_id": customer_id,
            "username":username,
            "password":password,
            "account_no":account_no,
          
        }
    
    def open_account_for_existing_customer(self, input_data, created_by_user_id, branch_id):
        # Generate new account number
    
        account = AccountCreate(
       
            branch_id=branch_id,
            savings_plan_id=input_data.savings_plan_id,
            balance=input_data.balance
        )
        acc_id,account_no = self.repo.create_account_for_existing_customer_by_nic(account.dict(), input_data.nic, created_by_user_id)
        if acc_id is None:
            raise HTTPException(status_code=404, detail="Customer with this NIC not found")
        return {
            "msg": "Account created for existing customer",
            "acc_id": acc_id,
            "account_no":account_no,
        
        }

    
    def get_accounts_by_branch(self, branch_id):
        """
        Get all accounts for a specific branch.
        """
        accounts = self.repo.get_accounts_by_branch(branch_id)
        return {"accounts": accounts, "total_count": len(accounts)}

    def get_account_balance_by_account_no(self, account_no):
        """
        Get the balance for a specific account by account number.
        """
        balance = self.repo.get_account_balance_by_account_no(account_no)
        if balance is None:
            raise HTTPException(status_code=404, detail="Account not found")
        return {"account_no": account_no, "balance": balance}

    def get_account_details_by_account_no(self, account_no):
        """
        Get customer name, account id, branch name, branch id, and balance using account_no.
        Returns: dict or None if not found.
        """
        details = self.repo.get_account_details_by_account_no(account_no)
        if not details:
            raise HTTPException(status_code=404, detail="Account not found")
        return details
    

    def get_account_count_by_branch(self, branch_id):
        """
        Get the total number of accounts for a specific branch, and the branch name.
        """
        result = self.repo.get_account_count_by_branch(branch_id)
        return result
    
    
    def get_total_account_count(self):
        """
        Get the total number of accounts in the system.
        """
        count = self.repo.get_total_account_count()
        return {"account_count": count}
    
    

    # Add more methods as needed, following this pattern.