from fastapi import APIRouter, Request
from app.middleware.require_permission import require_permission

router = APIRouter()    

@router.get("/my_profile")
@require_permission("admin")
async def my_profile(request: Request):
    # Example: return some user info from JWT
    return {"message": "My Profile", "user": getattr(request.state, "user", {})}

@router.get("/accounts")
@require_permission("account:view")
async def get_accounts(request: Request):

    return {"msg": "You can view accounts!", "permissions": request.state.user.get("permissions", [])}
