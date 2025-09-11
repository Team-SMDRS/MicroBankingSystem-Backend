 # All buisness logics put here

from app.core.utils import hash_password, verify_password, create_access_token
from fastapi import HTTPException

class UserService:

    def __init__(self, repo):
        self.repo = repo

    def register_user(self, user_data):
        existing = self.repo.get_login_by_username(user_data.username)
        if existing:
            raise HTTPException(status_code=400, detail="Username already exists")
        hashed = hash_password(user_data.password)
        user_id = self.repo.create_user(user_data, hashed)
        return {"msg": "User registered", "user_id": user_id}

    def login_user(self, login_data):
        row = self.repo.get_login_by_username(login_data.username)
        if not row or not verify_password(login_data.password, row["password"]):
            raise HTTPException(status_code=401, detail="Invalid username or password")
        
        token = create_access_token({"sub": row["username"], "user_id": str(row["user_id"])})
        return {"access_token": token, "token_type": "Bearer"}
