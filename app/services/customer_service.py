 # All business logics put here

from app.core.utils import (
    hash_password, 
    verify_password, 
    create_tokens, 
    hash_refresh_token, 
  
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
            user_data = {"sub": row["username"], "user_id": str(row["customer_id"])}
            tokens = create_tokens(user_data)
            
            # Extract device and IP info from request (if needed)
            
            return {
                "access_token": tokens["access_token"],
                "token_type": tokens["token_type"],
                "refresh_token": tokens["refresh_token"],
                "expires_in": tokens["refresh_token_expires_at"],  # 30 minutes in seconds
                "user_id": str(row["customer_id"]),
                "username": row["username"]
            }
        except HTTPException:
            raise
        except Exception as e:
            raise HTTPException(status_code=500, detail="Internal server error")
            
     
   

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

