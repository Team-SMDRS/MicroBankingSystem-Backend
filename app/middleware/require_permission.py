from fastapi import Request, HTTPException
from functools import wraps
import inspect

def require_permission(permission: str):
    print(f"Setting up permission requirement for: {permission}")
    def decorator(func):
        @wraps(func)
        async def wrapper(*args, **kwargs):
            # Look for request in both args and kwargs
            try:
                request: Request = kwargs.get("request") or next((a for a in args if isinstance(a, Request)), None)

                if not request or not getattr(request.state, "user", None):
                    raise HTTPException(status_code=401, detail="Unauthorized")
            except Exception as e:
                print(f"Error: {e}")
                raise

            user_perms = request.state.user.get("permissions", [])
            if not isinstance(user_perms, list):
                user_perms = []
            user_perms = [p.strip() for p in user_perms]

            print("Need permission:", permission)
            print("User permissions:", user_perms)

            if permission not in user_perms:
                raise HTTPException(status_code=403, detail=f"Permission '{permission}' denied")

            if inspect.iscoroutinefunction(func):
                return await func(*args, **kwargs)
            else:
                return func(*args, **kwargs)
        return wrapper
    return decorator
