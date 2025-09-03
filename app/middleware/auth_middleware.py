from starlette.middleware.base import BaseHTTPMiddleware
from starlette.responses import JSONResponse
from fastapi import Request
from app.core.utils import decode_access_token

class AuthMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        # Allow public paths
        public_paths = ["/login", "/register", "/docs", "/openapi.json","/","/favicon.ico","/redoc"]
        if request.url.path in public_paths:
            return await call_next(request)

        token = request.headers.get("Authorization")
        if not token or not token.startswith("Bearer "):
            return JSONResponse(status_code=401, content={"detail": "Missing token"})

        token = token.split(" ")[1]
        payload = decode_access_token(token)
        if not payload:
            return JSONResponse(status_code=401, content={"detail": "Invalid token"})

        request.state.user = payload
        return await call_next(request)
