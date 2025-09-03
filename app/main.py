from fastapi import FastAPI
from app.api import auth_routes
from app.middleware.auth_middleware import AuthMiddleware
from fastapi.responses import RedirectResponse

app = FastAPI()
# Middleware
app.add_middleware(AuthMiddleware)



# Routes
app.include_router(auth_routes.router)











@app.get("/")
async def root():
    return "Hello, Team SMTDS !"