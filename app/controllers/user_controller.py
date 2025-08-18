from fastapi import HTTPException, status
from fastapi.security import OAuth2PasswordRequestForm
from sqlalchemy.orm import Session
from app.services.user_service import create_user, authenticate_user
from app.utils import create_access_token, decode_access_token
from app.schemas import UserCreate, Token

def register_user(user: UserCreate, db: Session) -> Token:
    db_user = create_user(db, user.username, user.email, user.password)
    token = create_access_token({"sub": db_user.username})
    return {"access_token": token, "token_type": "bearer"}

def login_user(form_data: OAuth2PasswordRequestForm, db: Session) -> Token:
    user = authenticate_user(db, form_data.username, form_data.password)
    if not user:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid credentials")
    token = create_access_token({"sub": user.username})
    return {"access_token": token, "token_type": "bearer"}

def get_current_user(token: str):
    payload = decode_access_token(token)
    if not payload:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid token")
    return {"username": payload.get("sub")}
