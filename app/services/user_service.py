# All business logics put here

from app.core.utils import (
    hash_password, 
    verify_password, 
    create_tokens, 
    hash_refresh_token, 
    create_access_token_from_refresh
)
from fastapi import HTTPException, Request
from datetime import datetime, timedelta,timezone


class UserService:
    def __init__(self, repo):
        self.repo = repo

    def register_user(self, user_data, created_by_user_id, current_user):
        print(created_by_user_id)
        """Register a new user"""
        
        # Debug print of inputs
        print("User data received:", user_data)
        print("Created by user_id:", created_by_user_id)
        print("Current logged-in user:", current_user)

        # Check if username already exists
        existing = self.repo.get_login_by_username(user_data.username)
        if existing:
            raise HTTPException(status_code=400, detail="Username already exists")
        
        # Hash password
        hashed = hash_password(user_data.password)

        # Save user
        user_id = self.repo.create_user(user_data, hashed, created_by_user_id)
        return {"msg": "User registered", "user_id": user_id}


    def login_user(self, login_data, request: Request = None):
        """Login user and create both access and refresh tokens"""
        # Validate credentials
        row = self.repo.get_login_by_username(login_data.username)
        if not row or not verify_password(login_data.password, row["password"]):
            raise HTTPException(status_code=401, detail="Invalid username or password")
        
        
        # Create tokens (both access and refresh)
        user_data = {"sub": row["username"], "user_id": str(row["user_id"])}
        tokens = create_tokens(user_data)
        
        # Extract device and IP info from request
        ip_address = None
        device_info = None
        
        if request:
            # Get proper IP address (handles proxies and load balancers)
            def get_real_ip(request: Request) -> str:
                # Check X-Forwarded-For header first (for proxies/load balancers)
                x_forwarded_for = request.headers.get("x-forwarded-for")
                if x_forwarded_for:
                    return x_forwarded_for.split(",")[0].strip()
                
                # Check X-Real-IP header (nginx proxy)
                x_real_ip = request.headers.get("x-real-ip")
                if x_real_ip:
                    return x_real_ip.strip()
                
                # Fallback to direct client IP
                return request.client.host if request.client else "Unknown"
            
            ip_address = get_real_ip(request)
            device_info = request.headers.get("User-Agent", "Unknown")
            
            # Print login information for debugging
            
        else:
            print("⚠️ No request object received - IP and device info will be None")
        
        try:
            # Store refresh token in database
            token_id = self.repo.store_refresh_token(
                user_id=row["user_id"],
                token_hash=tokens["refresh_token_hash"],
                expires_at=tokens["refresh_token_expires_at"]
            )
            
            # Log login activity
            self.repo.insert_login_time(row["user_id"], ip_address, device_info)
            permissions = self.repo.get_user_permissions(row["user_id"])
           
            return {
                "access_token": tokens["access_token"],
                "refresh_token": tokens["refresh_token"],
                "token_type": tokens["token_type"],
                "expires_in": tokens["refresh_token_expires_at"],  # 30 minutes in seconds
                "user_id": str(row["user_id"]),
                "username": row["username"],
                 "permissions": permissions or []
            }
            
        except Exception as e:
            print(f"Login failed for user {row['username']}: {str(e)}")
            raise HTTPException(status_code=500, detail="Failed to create session")

    def refresh_access_token(self, refresh_token: str):
        """Create new access token using refresh token"""
        if not refresh_token:
            raise HTTPException(status_code=400, detail="Refresh token required")
        
        # Hash the provided refresh token
        token_hash = hash_refresh_token(refresh_token)
        
        # Get token data from database
        token_data = self.repo.get_refresh_token(token_hash)
        if not token_data:
            raise HTTPException(status_code=401, detail="Invalid or expired refresh token")
        
        # Get user data
        user = self.repo.get_user_by_id(token_data["user_id"])
        if not user:
            raise HTTPException(status_code=401, detail="User not found")
        
        # Create new access token
        user_data = {"sub": user["username"], "user_id": str(user["user_id"])}
        new_access_token = create_access_token_from_refresh(user_data)
        
        return {
            "access_token": new_access_token,
            "token_type": "Bearer",
            "expires_in": 1800  # 30 minutes
        }

    def logout_user(self, refresh_token: str, user_id: str):
        """Logout user by revoking refresh token"""
        if not refresh_token:
            raise HTTPException(status_code=400, detail="Refresh token required")
        
        token_hash = hash_refresh_token(refresh_token)
        success = self.repo.revoke_refresh_token(token_hash, user_id)
        
        if not success:
            raise HTTPException(status_code=400, detail="Failed to logout")
        
        return {"msg": "Successfully logged out"}

    def logout_all_devices(self, user_id: str):
        """Logout user from all devices by revoking all refresh tokens"""
        revoked_count = self.repo.revoke_all_user_tokens(user_id, user_id)
        return {"msg": f"Logged out from {revoked_count} devices"}

    def get_user_sessions(self, user_id: str):
        """Get all active sessions for a user"""
        active_tokens = self.repo.get_user_active_tokens(user_id)
        
        sessions = []
        for token in active_tokens:
            sessions.append({
                "token_id": str(token["token_id"]),
                "device_info": token["device_info"],
                "ip_address": str(token["ip_address"]) if token["ip_address"] else None,
                "created_at": token["created_at"].isoformat(),
                "expires_at": token["expires_at"].isoformat()
            })
        
        return {"sessions": sessions, "total_count": len(sessions)}

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

    def get_user_permissions(self, user_id: str):
        """Get user permissions"""
        permissions = self.repo.get_user_permissions(user_id)
        return {"permissions": permissions}

    def cleanup_expired_sessions(self):
        """Clean up expired refresh tokens"""
        deleted_count = self.repo.cleanup_expired_tokens()
        return {"msg": f"Cleaned up {deleted_count} expired sessions"}
    
    def get_user_roles(self, user_id: str):
        """Get roles for a specific user"""
        from fastapi import HTTPException
        
        if not self.repo.user_exists(user_id):
            raise HTTPException(status_code=404, detail="User not found")
        
        roles = self.repo.get_user_roles(user_id)
        return [{"role_id": str(role["role_id"]), "role_name": role["role_name"]} for role in roles]

    def get_all_users(self):
        """Get all users"""
        users = self.repo.get_all_users()
        result = []
        
        for user in users:
            result.append({
                "user_id": str(user["user_id"]),
                "nic": user["nic"],
                "first_name": user["first_name"],
                "last_name": user["last_name"],
                "address": user["address"],
                "phone_number": user["phone_number"],
                "dob": user["dob"].isoformat() if user["dob"] else None,
                "email": user["email"],
                "created_at": user["created_at"].isoformat()
            })
        
        return result

    def get_all_roles(self):
        """Get all available roles"""
        roles = self.repo.get_all_roles()
        return [{"role_id": str(role["role_id"]), "role_name": role["role_name"]} for role in roles]

    def manage_user_roles(self, user_id: str, role_ids: list):
        """Assign roles to a user"""
        from fastapi import HTTPException
        
        # Validate user exists
        if not self.repo.user_exists(user_id):
            raise HTTPException(status_code=404, detail="User not found")
        
        # Validate all role IDs exist
        all_roles = self.repo.get_all_roles()
        valid_role_ids = [str(role["role_id"]) for role in all_roles]
        
        for role_id in role_ids:
            if role_id not in valid_role_ids:
                raise HTTPException(status_code=400, detail=f"Role ID {role_id} does not exist")
        
        try:
            success = self.repo.assign_user_roles(user_id, role_ids)
            if success:
                return {"message": "User roles updated successfully", "user_id": user_id}
            else:
                raise HTTPException(status_code=500, detail="Failed to update user roles")
        except Exception as e:
            raise HTTPException(status_code=500, detail=f"Database error: {str(e)}")

    def get_users_with_roles(self):
        """Get all users with their roles grouped"""
        users_data = self.repo.get_users_with_roles()
        
        # Group users and their roles
        users_dict = {}
        
        for row in users_data:
            user_id = str(row["user_id"])
            
            if user_id not in users_dict:
                users_dict[user_id] = {
                    "user_id": user_id,
                    "nic": row["nic"],
                    "first_name": row["first_name"],
                    "last_name": row["last_name"],
                    "address": row["address"],
                    "phone_number": row["phone_number"],
                    "dob": row["dob"].isoformat() if row["dob"] else None,
                    "email": row["email"],
                    "created_at": row["created_at"].isoformat(),
                    "roles": []
                }
            
            # Add role if it exists
            if row["role_id"]:
                users_dict[user_id]["roles"].append({
                    "role_id": str(row["role_id"]),
                    "role_name": row["role_name"]
                })
        
        return list(users_dict.values())

    def update_user_password(self, request: Request, old_password: str, new_password: str):
        """Update user password after verifying the old password"""
        from fastapi import HTTPException
        current_user = getattr(request.state, "user", None)
        # Fetch user login info
        user_id = current_user["user_id"]
        username = current_user["sub"]

        row = self.repo.get_login_by_username(username)
        if not row or not verify_password(old_password, row["password"]):
            raise HTTPException(status_code=401, detail="Invalid username or password")
     

        # Hash new password
        new_hashed = hash_password(new_password)
        
        # Update password in database
        success = self.repo.update_user_password(current_user["user_id"], new_hashed)
        if not success:
            raise HTTPException(status_code=500, detail="Failed to update password")
        
        return {"msg": "Password updated successfully"}

    def get_user_by_id(self, user_id: str):
        """Get user by ID"""
        user = self.repo.get_user_by_id(user_id)
        if not user:
            raise HTTPException(status_code=404, detail="User not found")
        return user

    def get_transactions_by_user_id(self, user_id: str):
        """Get transactions for a specific user by their user ID"""
        transactions = self.repo.get_transactions_by_user_id(user_id)
        return transactions
    
    def get_today_transactions_by_user_id(self, user_id: str):
        """Get today's transactions for a specific user by their user ID and return totals (Sri Lanka time)"""
       

        # Sri Lanka is UTC+5:30
        sri_lanka_tz = timezone(timedelta(hours=5, minutes=30))
        today = datetime.now(sri_lanka_tz).date()
        today_start = datetime.combine(today, datetime.min.time(), tzinfo=sri_lanka_tz)
        today_end = datetime.combine(today, datetime.max.time(), tzinfo=sri_lanka_tz)
        raw_transactions = self.repo.get_transactions_by_user_id_and_date_range(user_id, today_start, today_end) or []
        
    

        transactions = []
        total_amount = 0.0
        totals_by_type = {
            "withdrawal": 0.0,
            "deposit": 0.0,
            "banktransfer_in": 0.0,
            "banktransfer_out": 0.0
        }
        # net: deposits and banktransfer-in positive, withdrawals and banktransfer-out negative
        net_amount = 0.0

        for tx in raw_transactions:
            amt = float(tx.get("amount") or 0)
            total_amount += amt

            tx_type_raw = (tx.get("type") or "").strip()
            tx_type = tx_type_raw.lower().replace(" ", "").replace("_", "")
            # normalize checks
            if tx_type in ("withdrawal",):
                totals_by_type["withdrawal"] += amt
                net_amount -= amt
            elif tx_type in ("deposit",):
                totals_by_type["deposit"] += amt
                net_amount += amt
            elif tx_type in ("banktransferin", "banktransfer-in", "banktransfer_in", "banktransferin"):
                totals_by_type["banktransfer_in"] += amt
                net_amount += amt
            elif tx_type in ("banktransferout", "banktransfer-out", "banktransfer_out", "banktransferout"):
                totals_by_type["banktransfer_out"] += amt
                net_amount -= amt
            else:
                # unknown types count as positive by default
                net_amount += amt

            transactions.append({
                "transaction_id": str(tx.get("transaction_id")),
                "amount": amt,
                "acc_id": str(tx.get("acc_id")) if tx.get("acc_id") else None,
                "type": tx.get("type"),
                "description": tx.get("description"),
                "created_at": tx.get("created_at").isoformat() if hasattr(tx.get("created_at"), "isoformat") else tx.get("created_at"),
                "created_by": str(tx.get("created_by")) if tx.get("created_by") else None,
                "reference_no": tx.get("reference_no")
            })

        summary = {
            "total_transactions": len(transactions),
            "total_amount": total_amount,                       # sum of amounts (all transactions)
            "total_withdrawal": totals_by_type["withdrawal"],
            "total_deposit": totals_by_type["deposit"],
            "total_banktransfer_in": totals_by_type["banktransfer_in"],
            "total_banktransfer_out": totals_by_type["banktransfer_out"],
            "sum_of_all_value": total_amount,                   # alias for total_amount
            "numeric_sum": net_amount                           # withdrawals negative, deposits positive
        }

        return {"transactions": transactions, "summary": summary}
    
    def update_user_details(self, request: Request, user_data):
        """Update user details (first name, last name, phone number, address, email) of a specific user"""
        from fastapi import HTTPException
        import re
        
        # Get the current user from the request (the one making the update)
        current_user = getattr(request.state, "user", None)
        if not current_user:
            raise HTTPException(status_code=401, detail="Unauthorized")
        
        # Check if the user to be updated exists
        target_user_id = user_data.user_id
        if not self.repo.user_exists(target_user_id):
            raise HTTPException(status_code=404, detail="User not found")
        
        # Check permissions - either the user is updating their own profile
        # or they have appropriate permissions
        current_user_id = current_user["user_id"]
        current_user_permissions = self.repo.get_user_permissions(current_user_id)
        
        # Allow if user is updating their own profile or has admin permissions
        is_self_update = current_user_id == target_user_id
        # has_admin_permission = "admin" in current_user_permissions
        
        # if not (is_self_update or has_admin_permission):
        #     raise HTTPException(status_code=403, detail="You don't have permission to update this user's details")
        
        # Validate email if provided
        if user_data.email:
            # Simple regex for email validation
            email_pattern = r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'
            if not re.match(email_pattern, user_data.email):
                raise HTTPException(status_code=400, detail="Invalid email format")
            
        # Update user details in the database
        success = self.repo.update_user_details(target_user_id, user_data)
        if not success:
            raise HTTPException(status_code=500, detail="Failed to update user details")
        
        return {"msg": "User details updated successfully"}
    

    def get_transactions_by_user_id_and_date_range(self, user_id: str, start_date: str, end_date: str):
        """Get transactions for a specific user by their user ID and date range"""

        try:
            start_dt = datetime.fromisoformat(start_date)
            end_dt = datetime.fromisoformat(end_date)
        except ValueError:
            raise HTTPException(status_code=400, detail="Invalid date format. Use ISO format YYYY-MM-DDTHH:MM:SS")

        if start_dt >= end_dt:
            raise HTTPException(status_code=400, detail="start_date must be before end_date")

        transactions = self.repo.get_transactions_by_user_id_and_date_range(user_id, start_dt, end_dt)
        return transactions