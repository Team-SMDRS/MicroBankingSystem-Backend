from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session
from ..schemas import UserCreate, UserOut
from ..services.user_service import create_user, authenticate_user
from ..db import get_db

router = APIRouter(prefix="/users", tags=["users"])

@router.post("/signup", response_model=UserOut)
def signup(user: UserCreate, db: Session = Depends(get_db)):
    db_user = create_user(db, user)
    return db_user

@router.post("/login")
def login(username: str, password: str, db: Session = Depends(get_db)):
    user = authenticate_user(db, username, password)
    if not user:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid credentials")
    return {"message": f"Welcome {user.username}!"}
