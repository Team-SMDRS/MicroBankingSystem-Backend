from sqlalchemy.orm import Session
from app import models
from app.utils import hash_password, verify_password, create_access_token

def create_user(db: Session, username: str, email: str, password: str):
    hashed_pw = hash_password(password)
    user = models.User(username=username, email=email, hashed_password=hashed_pw)
    db.add(user)
    db.commit()
    db.refresh(user)
    return user

def authenticate_user(db: Session, username: str, password: str):
    user = db.query(models.User).filter(models.User.username == username).first()
    if not user or not verify_password(password, user.hashed_password):
        return None
    return user

def create_token(user: models.User):
    access_token = create_access_token({"username": user.username})
    return {"access_token": access_token, "token_type": "bearer"}