# /login, /register

from fastapi import APIRouter, Depends, Request, HTTPException
from app.schemas.user_schema import RegisterUser, LoginUser, ManageUserRoles, UpdatePasswordRequest, UpdateUserRequest, DeactivateUserRequest
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
def logins(user: LoginUser, request: Request, db=Depends(get_db)):
    repo = UserRepository(db)
    service = UserService(repo)

    # Get real client IP address (handles proxies and load balancers)
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
        return request.client.host

    client_ip = get_real_ip(request)

    # login_user should return a dict like:
    # { "user_id": "...", "username": "...", "access_token": "...", "refresh_token": "...", "expires_in": datetime }
    result = service.login_user(user, request)  # ✅ Pass request here

    access_token = result["access_token"]
    refresh_token = result["refresh_token"]
    expires_in = result.get("expires_in")
    user_permission = result["permissions"]

    # Convert datetime to ISO string to avoid JSON serialization errors
    if isinstance(expires_in, datetime):
        expires_in = expires_in.isoformat()

    user_data = {
        "user_id": result["user_id"],
        "username": result["username"],
        "login_ip": client_ip
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
        samesite="Lax",     # ✅ allow sending cookie with localhost:5173 → localhost:8000
        path="/",
        max_age=7*24*60*60
    )

    return response



@router.get("/protected")
def protected(request: Request):
    return {"user": request.state.user, "message": "This is a protected route"}

@router.get("/roles/{user_id}")
def get_user_roles(user_id: str, db=Depends(get_db)):
    """Get all roles for a specific user"""
    repo = UserRepository(db)
    service = UserService(repo)
    
    try:
        roles = service.get_user_roles(user_id)
        return {"user_id": user_id, "roles": roles}
    except HTTPException as e:
        raise e
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Internal server error: {str(e)}")


@router.get("/api/all_users")
def get_all_users(db=Depends(get_db)):
    """Get all users with their roles"""
    repo = UserRepository(db)
    service = UserService(repo)
    
    try:
        users = service.get_users_with_roles()
        return {"users": users, "total_count": len(users)}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Internal server error: {str(e)}")


@router.get("/api/all_roles")
def get_all_roles(db=Depends(get_db)):
    """Get all available roles"""
    repo = UserRepository(db)
    service = UserService(repo)
    
    try:
        roles = service.get_all_roles()
        return {"roles": roles, "total_count": len(roles)}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Internal server error: {str(e)}")


@router.post("/user/manage_roles")
def manage_user_roles(role_data: ManageUserRoles, request: Request, db=Depends(get_db)):
    """Assign roles to a user"""
    repo = UserRepository(db)
    service = UserService(repo)
    
    try:
        result = service.manage_user_roles(role_data.user_id, role_data.role_ids)
        return result
    except HTTPException as e:
        raise e
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Internal server error: {str(e)}")

  

@router.post("/update_password")
def update_password(password_data: UpdatePasswordRequest, request: Request, db=Depends(get_db)):
    """Update user password"""
    repo = UserRepository(db)
    service = UserService(repo)
    
    try:
        result = service.update_user_password(request, password_data.old_password, password_data.new_password)
        return result
    except HTTPException as e:
        raise e
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Internal server error: {str(e)}")
    

@router.get("/user_data")
def get_user_data(request: Request, db=Depends(get_db)):
    """Get user data from access token"""
    repo = UserRepository(db)
    service = UserService(repo)
    
    try:
        current_user = getattr(request.state, "user", None)
        if not current_user:
            raise HTTPException(status_code=401, detail="Unauthorized")
        
        user_id = current_user["user_id"]
        user_data = service.get_user_by_id(user_id)
        return user_data
    except HTTPException as e:
        raise e
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Internal server error: {str(e)}")
    
@router.get("/user/transactions_history")
def get_user_transactions(request: Request, db=Depends(get_db)):
    """Get transactions for the logged-in user"""
    repo = UserRepository(db)
    service = UserService(repo)
    
    try:
        current_user = getattr(request.state, "user", None)
        if not current_user:
            raise HTTPException(status_code=401, detail="Unauthorized")
        
        user_id = current_user["user_id"]
        transactions = service.get_transactions_by_user_id(user_id)
        return {"transactions": transactions, "total_count": len(transactions)}
    except HTTPException as e:
        raise e
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Internal server error: {str(e)}")


@router.get("/user/today_transactions")
def get_user_today_transactions(request: Request, db=Depends(get_db)):
    """Get today's transactions for the logged-in user"""
    repo = UserRepository(db)
    service = UserService(repo)

    try:
        current_user = getattr(request.state, "user", None)
        if not current_user:
            raise HTTPException(status_code=401, detail="Unauthorized")

        user_id = current_user["user_id"]
        transactions = service.get_today_transactions_by_user_id(user_id)
        return {"transactions": transactions, "total_count": len(transactions)}
    except HTTPException as e:
        raise e
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Internal server error: {str(e)}")
    
@router.get("/user/transactions_by_date_range")
def get_user_transactions_by_date_range(start_date: str, end_date: str, request: Request, db=Depends(get_db)):
    """Get transactions for the logged-in user by date range"""
    repo = UserRepository(db)
    service = UserService(repo)

    try:
        current_user = getattr(request.state, "user", None)
        if not current_user:
            raise HTTPException(status_code=401, detail="Unauthorized")

        user_id = current_user["user_id"]
        transactions = service.get_transactions_by_user_id_and_date_range(user_id, start_date, end_date)
        return {"transactions": transactions, "total_count": len(transactions)}
    except HTTPException as e:
        raise e
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Internal server error: {str(e)}")
        
@router.put("/user/update_details")
def update_user_details(user_data: UpdateUserRequest, request: Request, db=Depends(get_db)):
    """Update user details (first name, last name, phone number, address, email) of a specific user"""
    repo = UserRepository(db)
    service = UserService(repo)
    
    try:
        result = service.update_user_details(request, user_data)
        return result
    except HTTPException as e:
        raise e
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Internal server error: {str(e)}")
        
@router.put("/user/deactivate")
def deactivate_user(user_data: DeactivateUserRequest, request: Request, db=Depends(get_db)):
    """Deactivate a user by setting their status to 'inactive'"""
    repo = UserRepository(db)
    service = UserService(repo)
    
    try:
        result = service.deactivate_user(request, user_data.user_id)
        return result
    except HTTPException as e:
        raise e
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Internal server error: {str(e)}")