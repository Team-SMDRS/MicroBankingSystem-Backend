   # /login, /register

from fastapi import APIRouter, Depends, Request
from app.schemas.user_schema import RegisterUser, LoginUser
from app.database.db import get_db
from app.repositories.user_repo import UserRepository
from app.services.user_service import UserService
from fastapi.responses import JSONResponse
from datetime import datetime

router = APIRouter()



@router.post("/register")
def register(user: RegisterUser, request: Request, db=Depends(get_db)):
    repo = UserRepository(db)
    service = UserService(repo)

    current_user = getattr(request.state, "user", None)

    return service.register_user(
        user_data=user,
        created_by_user_id=current_user["user_id"] if current_user else None,
        current_user=current_user
    )






@router.post("/login")
def logins(user: LoginUser, db=Depends(get_db)):
    repo = UserRepository(db)
    service = UserService(repo)

    # login_user should return a dict like:
    # { "user_id": "...", "username": "...", "access_token": "...", "refresh_token": "...", "expires_in": datetime }
    result = service.login_user(user)

    access_token = result["access_token"]
    refresh_token = result["refresh_token"]
    expires_in = result.get("expires_in")
    user_permission = result["permissions"]

    # Convert datetime to ISO string to avoid JSON serialization errors
    if isinstance(expires_in, datetime):
        expires_in = expires_in.isoformat()

    user_data = {
        "user_id": result["user_id"],
        "username": result["username"]
    }

    # create JSON response with only access token and user info
    response = JSONResponse(content={
        "access_token": access_token,
        "user": user_data,
        "token_type": "Bearer",
        "expires_in": expires_in,
        "permissions":user_permission
    })

    # set refresh token in HttpOnly cookie
    response.set_cookie(
        key="refresh_token",
        value=refresh_token,
        httponly=True,
        secure=False,       # ✅ must be False on http://localhost
        samesite="lax",     # ✅ allow sending cookie with localhost:5173 → localhost:8000
        path="/",
        max_age=7*24*60*60
    )

    return response



@router.get("/protected")
def protected(request: Request):
    return {"user": request.state.user}
