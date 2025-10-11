import random

import string
from fastapi import HTTPException
from app.schemas.account_management_schema import CustomerAccountInput, CustomerCreate, CustomerLoginCreate, AccountCreate, RegisterCustomerWithAccount
from app.core.utils import hash_password

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
        """
        Register a new customer with account and auto-generated login credentials.
        
        Args:
            input_data: CustomerAccountInput containing customer and account details
            created_by_user_id: UUID of the user creating the customer
            branch_id: ID of the branch where account is created
            
        Returns:
            dict: Success message with customer and account details
            
        Raises:
            HTTPException: For various error conditions
        """
        try:
            # Validate input data
            if not input_data.full_name or not input_data.full_name.strip():
                raise HTTPException(status_code=400, detail="Full name is required")
                
            if not input_data.nic or not str(input_data.nic).strip():
                raise HTTPException(status_code=400, detail="NIC is required")
                
            if not input_data.dob:
                raise HTTPException(status_code=400, detail="Date of birth is required")
                
            if not input_data.savings_plan_id:
                raise HTTPException(status_code=400, detail="Savings plan ID is required")
                
            # Validate NIC format
            nic = str(input_data.nic).strip()
            if len(nic) < 9 or len(nic) > 12:
                raise HTTPException(status_code=400, detail="Invalid NIC format (must be 9-12 characters)")
                
            # Validate full name format
            full_name = input_data.full_name.strip()
            if len(full_name) < 2:
                raise HTTPException(status_code=400, detail="Full name must be at least 2 characters")
                
            # Validate balance
            balance = getattr(input_data, 'balance', 0.0)
            if balance < 0:
                raise HTTPException(status_code=400, detail="Balance cannot be negative")
                
            # Validate phone number if provided
            if hasattr(input_data, 'phone_number') and input_data.phone_number:
                phone = str(input_data.phone_number).strip()
                if len(phone) < 10 or not phone.replace('+', '').replace('-', '').replace(' ', '').isdigit():
                    raise HTTPException(status_code=400, detail="Invalid phone number format")
                    
            # Validate branch_id and user_id
            if not branch_id:
                raise HTTPException(status_code=400, detail="Branch ID is required")
                
            if not created_by_user_id:
                raise HTTPException(status_code=400, detail="Created by user ID is required")
                
            # Auto-generate username and password
            username = self._generate_username(full_name)
            password = self._generate_password()
            hashed_password = hash_password(password)
            # Ensure username uniqueness by adding retry logic
            original_username = username
            retry_count = 0
            max_retries = 5
            
            while retry_count < max_retries:
                try:
                    # Create customer object
                    customer = CustomerCreate(
                        full_name=full_name,
                        address=getattr(input_data, 'address', None),
                        phone_number=getattr(input_data, 'phone_number', None),
                        nic=nic,
                        dob=input_data.dob
                    )
                    
                    # Create login object
                    login = CustomerLoginCreate(
                        username=username,
                        password=hashed_password  # In production, hash this!
                    )
                    
                    # Create account object
                    account = AccountCreate(
                        branch_id=branch_id,
                        savings_plan_id=input_data.savings_plan_id,
                        balance=balance,
                        status=getattr(input_data, 'status', 'active')
                    )
                    
                    # Attempt to create customer with login and account
                    result = self.repo.create_customer_with_login(
                        customer.dict(), 
                        login.dict(), 
                        created_by_user_id, 
                        account.dict()
                    )
                    
                    # Validate repository response
                    if not result or len(result) != 2:
                        raise HTTPException(
                            status_code=500, 
                            detail="Unexpected response format from repository"
                        )
                        
                    customer_id, account_no = result
                    
                    # Validate returned data
                    if not customer_id or not account_no:
                        raise HTTPException(
                            status_code=500, 
                            detail="Failed to create customer/account - invalid response"
                        )
                    
                    return {
                        "msg": "Customer registered and account created successfully",
                        "customer_id": customer_id,
                        "username": username,
                        "password": password,
                        "account_no": account_no,
                        "nic": nic,
                        "full_name": full_name,
                        "branch_id": branch_id,
                        "balance": balance
                    }
                    
                except Exception as e:
                    error_msg = str(e).lower()
                    
                    # Check if it's a username conflict
                    if "username" in error_msg and ("duplicate" in error_msg or "unique" in error_msg):
                        retry_count += 1
                        username = f"{original_username}{retry_count}"
                        continue
                    else:
                        # Re-raise for other types of errors
                        raise e
                        
            # If we've exhausted retries for username generation
            raise HTTPException(
                status_code=500, 
                detail="Failed to generate unique username after multiple attempts"
            )
            
        except HTTPException:
            # Re-raise HTTP exceptions as-is
            raise
            
        except ValueError as e:
            # Handle data conversion errors
            raise HTTPException(
                status_code=400, 
                detail=f"Invalid data format: {str(e)}"
            )
            
        except Exception as e:
            # Handle database or other unexpected errors
            error_msg = str(e).lower()
            
            # Check for specific database constraint violations
            if "nic" in error_msg and ("duplicate" in error_msg or "unique" in error_msg):
                raise HTTPException(
                    status_code=409, 
                    detail="Customer with this NIC already exists"
                )
            elif "foreign key" in error_msg:
                if "savings" in error_msg:
                    raise HTTPException(
                        status_code=400, 
                        detail="Invalid savings plan ID"
                    )
                elif "branch" in error_msg:
                    raise HTTPException(
                        status_code=400, 
                        detail="Invalid branch ID"
                    )
                else:
                    raise HTTPException(
                        status_code=400, 
                        detail="Invalid reference data provided"
                    )
            elif "connection" in error_msg:
                raise HTTPException(
                    status_code=503, 
                    detail="Database connection error - please try again"
                )
            elif "timeout" in error_msg:
                raise HTTPException(
                    status_code=408, 
                    detail="Request timeout - please try again"
                )
            else:
                # Generic error for unexpected issues
                raise HTTPException(
                    status_code=500, 
                    detail="Failed to register customer - internal server error"
                )
    
    def open_account_for_existing_customer(self, input_data, created_by_user_id, branch_id):
        """
        Open a new account for an existing customer by NIC.
        
        Args:
            input_data: Object containing nic, savings_plan_id, balance
            created_by_user_id: UUID of the user creating the account
            branch_id: ID of the branch where account is created
            
        Returns:
            dict: Success message with account details
            
        Raises:
            HTTPException: For various error conditions
        """
        try:
            # Validate input data
            if not hasattr(input_data, 'nic') or not input_data.nic:
                raise HTTPException(status_code=400, detail="NIC is required")
                
            if not hasattr(input_data, 'savings_plan_id') or not input_data.savings_plan_id:
                raise HTTPException(status_code=400, detail="Savings plan ID is required")
                
            # Validate NIC format (basic validation)
            nic = str(input_data.nic).strip()
            if len(nic) < 9 or len(nic) > 12:
                raise HTTPException(status_code=400, detail="Invalid NIC format")
                
            # Validate balance
            balance = getattr(input_data, 'balance', 0.0)
            if balance < 0:
                raise HTTPException(status_code=400, detail="Balance cannot be negative")
                
            # Validate branch_id and user_id
            if not branch_id:
                raise HTTPException(status_code=400, detail="Branch ID is required")
                
            if not created_by_user_id:
                raise HTTPException(status_code=400, detail="Created by user ID is required")

            # Create account object
            account = AccountCreate(
                branch_id=branch_id,
                savings_plan_id=input_data.savings_plan_id,
                balance=balance
            )
            
            # Attempt to create account
            result = self.repo.create_account_for_existing_customer_by_nic(
                account.dict(), 
                nic, 
                created_by_user_id
            )
            
            # Handle repository response
            if result is None:
                raise HTTPException(
                    status_code=404, 
                    detail="Customer with this NIC not found"
                )
                
            # Unpack result
            if isinstance(result, tuple) and len(result) == 2:
                acc_id, account_no = result
            else:
                raise HTTPException(
                    status_code=500, 
                    detail="Unexpected response format from repository"
                )
                
            # Validate returned data
            if not acc_id or not account_no:
                raise HTTPException(
                    status_code=500, 
                    detail="Failed to create account - invalid response"
                )
                
            return {
                "msg": "Account created successfully for existing customer",
                "acc_id": acc_id,
                "account_no": account_no,
                "nic": nic,
                "balance": balance,
                "branch_id": branch_id
            }
            
        except HTTPException:
            # Re-raise HTTP exceptions as-is
            raise
            
        except ValueError as e:
            # Handle data conversion errors
            raise HTTPException(
                status_code=400, 
                detail=f"Invalid data format: {str(e)}"
            )
            
        except Exception as e:
            # Handle database or other unexpected errors
            error_msg = str(e)
            
            # Check for common database constraint violations
            if "duplicate" in error_msg.lower() or "unique" in error_msg.lower():
                raise HTTPException(
                    status_code=409, 
                    detail="Account creation failed - data conflict"
                )
            elif "foreign key" in error_msg.lower():
                raise HTTPException(
                    status_code=400, 
                    detail="Invalid savings plan ID or branch ID"
                )
            elif "connection" in error_msg.lower():
                raise HTTPException(
                    status_code=503, 
                    detail="Database connection error - please try again"
                )
            else:
                # Generic error for unexpected issues
                raise HTTPException(
                    status_code=500, 
                    detail="Failed to create account - internal server error"
                )
    
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


    def close_account_by_account_no(self, account_no, closed_by_user_id=None):
        """
        Close (soft-delete) an account by setting its status to 'closed'.
        Returns the previous balance and the updated account record.
        """
        try:
            result = self.repo.close_account_by_account_no(account_no, closed_by_user_id)
            if not result:
                raise HTTPException(status_code=404, detail="Account not found")

            # Expecting result to be dict { previous_balance: <val>, account_no, savings_plan_name, updated_at, status }
            previous_balance = result.get('previous_balance') if isinstance(result, dict) else None
            account_no = result.get('account_no') if isinstance(result, dict) else None
            savings_plan_name = result.get('savings_plan_name') if isinstance(result, dict) else None
            updated_at = result.get('updated_at') if isinstance(result, dict) else None
            status = result.get('status') if isinstance(result, dict) else None

            return {
                "msg": "Account closed successfully",
                "previous_balance": previous_balance,
                "account_no": account_no,
                "savings_plan_name": savings_plan_name,
                "updated_at": updated_at,
                "status": status
            }
        except HTTPException:
            raise
        except Exception as e:
            raise HTTPException(status_code=500, detail="Failed to close account")
    
    

    # Add more methods as needed, following this pattern.