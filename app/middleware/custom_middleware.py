from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import Response

class CustomMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        print(f"Incoming request: {request.method} {request.url}")
        
        # You can add custom logic here before request processing
        
        response: Response = await call_next(request)
        
        # Add custom header to the response
        response.headers["X-Custom-Middleware"] = "Active"
        
        # You can add custom logic here after response is generated
        
        return response
