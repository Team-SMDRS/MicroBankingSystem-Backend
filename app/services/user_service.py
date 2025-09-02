 # password hash/verify, JWT encode/decode

from sqlalchemy.orm import Session
from app.models import User
from app.utils import hash_password, verify_password

def create_user(db: Session, username: str, email: str, password: str) -> User:
    hashed_password = hash_password(password)
    user = User(username=username, email=email, hashed_password=hashed_password)
    db.add(user)
    db.commit()
    db.refresh(user)
    return user

def authenticate_user(db: Session, username: str, password: str) -> User:
    user = db.query(User).filter(User.username == username).first()
    if not user or not verify_password(password, user.hashed_password):
        return None
    return user
