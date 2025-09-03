   # /login, /register

from fastapi import APIRouter, Depends, Request
from app.schemas.user_schema import RegisterUser, LoginUser
from app.database.db import get_db
from app.repositories.user_repo import UserRepository
from app.services.user_service import UserService

router = APIRouter()

@router.post("/register")
def register(user: RegisterUser, db=Depends(get_db)):
    repo = UserRepository(db)
    service = UserService(repo)
    return service.register_user(user)

@router.post("/login")
def login(user: LoginUser, db=Depends(get_db)):
    repo = UserRepository(db)
    service = UserService(repo)
    return service.login_user(user)

@router.get("/protected")
def protected(request: Request):
    return {"user": request.state.user}
