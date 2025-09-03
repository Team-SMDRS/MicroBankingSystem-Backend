from fastapi import FastAPI , Request
from app.api import auth_routes
from app.middleware.auth_middleware import AuthMiddleware
from app.api import account_routes
from fastapi.responses import JSONResponse

#from fastapi.middleware.cors import CORSMiddleware
app = FastAPI()
# Middleware

app.add_middleware(AuthMiddleware)



# Routes
app.include_router(auth_routes.router)
app.include_router(account_routes.router)
app.include_router(account_routes.router)






@app.get("/")
async def root():
    return "Hello, Team SMTDS !"


# app.add_middleware(
#     CORSMiddleware,
#     allow_origins=["*"],  # change to your allowed origins
#     allow_credentials=True,
#     allow_methods=["*"],
#     allow_headers=["*"],
# )

@app.exception_handler(404)
async def not_found_handler(request: Request, exc):
    return JSONResponse(
        status_code=404,
        content={"error": "Route not found. Please check the URL."}
    )