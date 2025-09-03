 # JWT verification + role check

from fastapi import Request, HTTPException
from starlette.middleware.base import BaseHTTPMiddleware
from app.utils import decode_access_token

class AuthMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        if request.url.path in ["/login", "/register", "/docs", "/openapi.json","/","/favicon.ico","/redoc"]:
            return await call_next(request)

        token = request.headers.get("Authorization")
        if not token or not token.startswith("Bearer "):
            raise HTTPException(status_code=401, detail="Missing token")

        token = token.split(" ")[1]
        payload = decode_access_token(token)
        if not payload:
            raise HTTPException(status_code=401, detail="Invalid token")

        request.state.user = payload  # contains username + user_id
        return await call_next(request)
