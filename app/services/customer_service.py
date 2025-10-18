# All business logics put here
from fastapi import HTTPException
from app.core.utils import (
    hash_password, 
    verify_password, 
    create_access_token_for_customer,
    generate_refresh_token,
    hash_refresh_token,
    get_refresh_token_expiry
)
from fastapi import HTTPException, Request
class CustomerService:
    
    def __init__(self, repo):
        self.repo = repo

    

    def login_customer(self, login_data, request: Request = None):
        """Login user and create both access and refresh tokens"""
        try:
            # Validate credentials
            row = self.repo.get_customer_login_by_username(login_data.username)
            if not row or not verify_password(login_data.password, row["password"]):
                raise HTTPException(status_code=401, detail="Invalid username or password")
            
            # Create tokens (both access and refresh)
            user_data = {"sub": row["username"], "customer_id": str(row["customer_id"])}
            access_token = create_access_token_for_customer(user_data)
            refresh_token = generate_refresh_token()
            refresh_token_hash = hash_refresh_token(refresh_token)
            refresh_token_expires_at = get_refresh_token_expiry()
            
            # Extract device and IP info from request (if needed)
            
            return {
                "access_token": access_token,
                "token_type": "Bearer",
                "refresh_token": refresh_token,
                "expires_in": refresh_token_expires_at,  # 30 minutes in seconds
                "user_id": str(row["customer_id"]),
                "username": row["username"]
            }
        except HTTPException:
            raise
        except Exception as e:
            raise HTTPException(status_code=500, detail="Internal server error: " + str(e))


    def logout_user(self, refresh_token: str, user_id: str):
        """Logout user by revoking refresh token"""
        if not refresh_token:
            raise HTTPException(status_code=400, detail="Refresh token required")
        
        token_hash = hash_refresh_token(refresh_token)
        success = self.repo.revoke_refresh_token(token_hash, user_id)
        
        if not success:
            raise HTTPException(status_code=400, detail="Failed to logout")
        
        return {"msg": "Successfully logged out"}



  
    def get_user_profile(self, user_id: str):
        """Get user profile information"""
        user = self.repo.get_user_by_id(user_id)
        if not user:
            raise HTTPException(status_code=404, detail="User not found")
        
        return {
            "user_id": str(user["user_id"]),
            "username": user["username"],
            "first_name": user["first_name"],
            "last_name": user["last_name"],
            "nic": user["nic"],
            "address": user["address"],
            "phone_number": user["phone_number"],
            "dob": user["dob"].isoformat() if user["dob"] else None,
            "created_at": user["created_at"].isoformat()
        }

    def get_customer_by_nic(self, nic: str):
        """
        Return minimal customer info by NIC (customer_id, full_name, nic)
        Raises 404 HTTPException if not found.
        """
        row = self.repo.get_customer_by_nic(nic)
        from fastapi import HTTPException
        if not row:
            raise HTTPException(status_code=404, detail="Customer not found")
        return {
            "customer_id": row["customer_id"],
            "full_name": row["full_name"],
            "nic": row["nic"]
        }
    
    def get_customer_details_by_nic(self, nic: str):
        """
        Return detailed customer information by NIC (including creator's name).
        """
        row = self.repo.get_customer_details_by_nic(nic)
        if not row:
            raise HTTPException(status_code=404, detail="Customer not found")
        return {
            "customer_id": row["customer_id"],
            "full_name": row["full_name"],
            "nic": row["nic"],
            "address": row.get("address"),
            "phone_number": row.get("phone_number"),
            "dob": row["dob"].isoformat() if row.get("dob") else None,
            "created_by_user_name": row.get("created_by_user_name")
        }
    
    def get_complete_customer_details(self, customer_id: str):
        """
        Get complete customer details including:
        - Customer profile
        - All accounts with balances
        - All transactions
        - All fixed deposits
        Returns: Comprehensive customer data dict
        """
        # Get customer profile
        customer = self.repo.get_customer_by_id(customer_id)
        if not customer:
            raise HTTPException(status_code=404, detail="Customer not found")
        
        # Get all accounts
        accounts = self.repo.get_customer_accounts(customer_id)
        
        # Get all transactions
        transactions = self.repo.get_customer_transactions(customer_id)
        
        # Get all fixed deposits
        fixed_deposits = self.repo.get_customer_fixed_deposits(customer_id)
        
        # Calculate total balances
        total_savings_balance = sum(float(acc.get('balance', 0)) for acc in accounts if acc.get('status') == 'active')
        total_fd_balance = sum(float(fd.get('balance', 0)) for fd in fixed_deposits if fd.get('status') == 'active')
        
        return {
            "customer_profile": {
                "customer_id": str(customer["customer_id"]),
                "full_name": customer["full_name"],
                "nic": customer["nic"],
                "address": customer.get("address"),
                "phone_number": customer.get("phone_number"),
                "dob": customer["dob"].isoformat() if customer.get("dob") else None,
                "created_at": customer["created_at"].isoformat() if customer.get("created_at") else None
            },
            "accounts": [
                {
                    "acc_id": str(acc["acc_id"]),
                    "account_no": str(acc["account_no"]),
                    "balance": float(acc["balance"]) if acc.get("balance") else 0,
                    "status": acc["status"],
                    "opened_date": acc["opened_date"].isoformat() if acc.get("opened_date") else None,
                    "branch_name": acc["branch_name"],
                    "branch_id": str(acc["branch_id"]),
                    "savings_plan": acc["savings_plan"]
                }
                for acc in accounts
            ],
            "transactions": [
                {
                    "transaction_id": str(trans["transaction_id"]),
                    "reference_no": str(trans["reference_no"]) if trans.get("reference_no") else None,
                    "amount": float(trans["amount"]),
                    "type": trans["type"],
                    "description": trans.get("description"),
                    "created_at": trans["created_at"].isoformat() if trans.get("created_at") else None,
                    "account_no": str(trans["account_no"])
                }
                for trans in transactions
            ],
            "fixed_deposits": [
                {
                    "fd_id": str(fd["fd_id"]),
                    "fd_account_no": str(fd["fd_account_no"]),
                    "balance": float(fd["balance"]) if fd.get("balance") else 0,
                    "opened_date": fd["opened_date"].isoformat() if fd.get("opened_date") else None,
                    "maturity_date": fd["maturity_date"].isoformat() if fd.get("maturity_date") else None,
                    "status": fd["status"],
                    "linked_savings_account": str(fd["linked_savings_account"]),
                    "duration": fd["duration"],
                    "interest_rate": float(fd["interest_rate"]) if fd.get("interest_rate") else 0,
                    "branch_name": fd["branch_name"]
                }
                for fd in fixed_deposits
            ],
            "summary": {
                "total_accounts": len(accounts),
                "active_accounts": len([acc for acc in accounts if acc.get('status') == 'active']),
                "total_savings_balance": total_savings_balance,
                "total_fd_balance": total_fd_balance,
                "total_balance": total_savings_balance + total_fd_balance,
                "total_transactions": len(transactions),
                "total_fixed_deposits": len(fixed_deposits),
                "active_fixed_deposits": len([fd for fd in fixed_deposits if fd.get('status') == 'active'])
            }
        }

