from passlib.context import CryptContext
from datetime import datetime, timedelta
from jose import jwt, JWTError
import secrets
import hashlib

SECRET_KEY = "supersecretkey"
SECRET_KEY_FOR_CUSTOMER = "ALIBABA"
ALGORITHM = "HS256"
ACCESS_TOKEN_EXPIRE_MINUTES = 30  # Standard 30 minutes
REFRESH_TOKEN_EXPIRE_DAYS = 7  # Standard 7 days

pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")

def hash_password(password: str):
    return pwd_context.hash(password)

def verify_password(password: str, hashed: str):
    return pwd_context.verify(password, hashed)

def create_access_token(data: dict):
    to_encode = data.copy()
    expire = datetime.utcnow() + timedelta(minutes=ACCESS_TOKEN_EXPIRE_MINUTES)
    to_encode.update({"exp": expire})
    return jwt.encode(to_encode, SECRET_KEY, algorithm=ALGORITHM)



def create_access_token_for_customer(data: dict):
    to_encode = data.copy()
    expire = datetime.utcnow() + timedelta(minutes=ACCESS_TOKEN_EXPIRE_MINUTES)
    to_encode.update({"exp": expire})
    return jwt.encode(to_encode, SECRET_KEY_FOR_CUSTOMER, algorithm=ALGORITHM)


def decode_access_token(token: str):
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
        return payload
    except JWTError:
        return None
    
def decode_access_token_for_customer(token: str):
    try:
        payload = jwt.decode(token, SECRET_KEY_FOR_CUSTOMER, algorithms=[ALGORITHM])
        return payload
    except JWTError:
        return None


# Refresh Token Functions
def generate_refresh_token() -> str:
    """Generate a secure random refresh token"""
    return secrets.token_urlsafe(32)

def hash_refresh_token(token: str) -> str:
    """Hash refresh token for secure storage"""
    return hashlib.sha256(token.encode()).hexdigest()

def verify_refresh_token(token: str, hashed_token: str) -> bool:
    """Verify refresh token against its hash"""
    return hashlib.sha256(token.encode()).hexdigest() == hashed_token

def get_refresh_token_expiry() -> datetime:
    """Get expiry datetime for refresh token"""
    return datetime.utcnow() + timedelta(days=REFRESH_TOKEN_EXPIRE_DAYS)

def create_tokens(user_data: dict) -> dict:
    """Create both access and refresh tokens"""
    access_token = create_access_token(user_data)
    refresh_token = generate_refresh_token()
    
    return {
        "access_token": access_token,
        "refresh_token": refresh_token,
        "refresh_token_hash": hash_refresh_token(refresh_token),
        "refresh_token_expires_at": get_refresh_token_expiry(),
        "token_type": "Bearer"
    }

def create_access_token_from_refresh(user_data: dict) -> str:
    """Create new access token when refreshing"""
    return create_access_token(user_data)
