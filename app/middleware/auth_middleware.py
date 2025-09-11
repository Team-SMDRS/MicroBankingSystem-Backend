from starlette.middleware.base import BaseHTTPMiddleware
from starlette.responses import JSONResponse
from fastapi import Request
from app.core.utils import decode_access_token
from app.repositories.user_repo import UserRepository
from app.database.db import get_db

class AuthMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        public_paths = ["/api/auth/login", "/api/auth/register", "/docs", "/openapi.json", "/", "/favicon.ico", "/redoc"]
        if request.url.path in public_paths:
            return await call_next(request)

        token = request.headers.get("Authorization")
        if not token or not token.startswith("Bearer "):
            return JSONResponse(status_code=401, content={"detail": "Missing token"})

        token = token.split(" ")[1]
        payload = decode_access_token(token)
        if not payload:
            return JSONResponse(status_code=401, content={"detail": "Invalid token"})

        user_id = payload["user_id"]

        # fetch permissions from DB
        try:
            conn = get_db()
            repo = UserRepository(conn)
            permissions = repo.get_user_permissions(user_id)
        finally:
            conn.close()

        # Attach to request.state
        request.state.user = payload
        print("User state:", getattr(request.state, "user", None))

        request.state.user["permissions"] = permissions or []
        print("User state:", getattr(request.state, "user", None))

        return await call_next(request)
