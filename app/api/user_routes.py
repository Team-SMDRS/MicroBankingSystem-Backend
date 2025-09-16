from fastapi import APIRouter, Depends, HTTPException
from app.services.user_service import UserService
from app.schemas.user_schema import UserCreate
from app.api.auth_routes import get_current_user_id

router = APIRouter()
# You must initialize UserService with your actual repository instance
user_service = UserService(repo=...)

@router.post("/register")
def register_user(
    user_data: UserCreate,
    current_user_id: str = Depends(get_current_user_id)
):
    return user_service.register_user(user_data, created_by_user_id=current_user_id)