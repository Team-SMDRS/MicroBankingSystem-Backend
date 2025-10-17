from starlette.middleware.base import BaseHTTPMiddleware
from starlette.responses import JSONResponse
from fastapi import Request
from app.core.utils import decode_access_token
from app.repositories.user_repo import UserRepository
from app.database.db import get_db
from datetime import datetime

class AuthMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        # ADD THIS: Allow OPTIONS requests to pass through without auth
        if request.method == "OPTIONS":
            return await call_next(request)
            
        public_paths = [
            "/api/auth/login", 
            # "/api/auth/register", 
            "/api/auth/refresh",  # Add refresh endpoint to public paths
            "/docs", 
            "/openapi.json", 
            "/", 
            "/favicon.ico", 
            "/redoc",
            "/customer_data/login",
            "/customer_data/my_profile"
        ]
        if request.url.path in public_paths:
            return await call_next(request)

        # Extract and validate Authorization header
        auth_header = request.headers.get("Authorization")
        if not auth_header or not auth_header.startswith("Bearer "):
            return JSONResponse(
                status_code=401, 
                content={"detail": "Missing or invalid authorization header"}
            )

        # Extract token
        token = auth_header.split(" ")[1]
        
        # Decode and validate access token
        payload = decode_access_token(token)
        if not payload:
            return JSONResponse(
                status_code=401, 
                content={
                    "detail": "Invalid or expired access token",
                    "error_code": "TOKEN_INVALID"
                }
            )

        # Check token expiration (additional safety check)
        if "exp" in payload:
            if datetime.utcnow().timestamp() > payload["exp"]:
                return JSONResponse(
                    status_code=401,
                    content={
                        "detail": "Access token has expired",
                        "error_code": "TOKEN_EXPIRED"
                    }
                )

        user_id = payload.get("user_id")
        if not user_id:
            return JSONResponse(
                status_code=401,
                content={
                    "detail": "Invalid token payload",
                    "error_code": "TOKEN_INVALID"
                }
            )

        # Fetch user permissions and branch from database
        conn = None
        try:
            
            conn = get_db()
            repo = UserRepository(conn)
            
            permissions = repo.get_user_permissions(user_id)
            branch_id = repo.get_user_branch_id(user_id)
            
            
            # Verify user still exists and is active
            user_exists = repo.get_user_by_id(user_id)
            if not user_exists:
                return JSONResponse(
                    status_code=401,
                    content={
                        "detail": "User no longer exists",
                        "error_code": "USER_NOT_FOUND"
                    }
                )
                
        except Exception as e:
            return JSONResponse(
                status_code=500,
                content={"detail": "Database error during authentication", "error": str(e)}
            )
        finally:
            if conn:
                conn.close()

        # Attach user data to request state
        request.state.user = payload
        request.state.user["permissions"] = permissions or []
        request.state.user["user_id"] = user_id
        request.state.user["branch_id"] = branch_id

        return await call_next(request)
