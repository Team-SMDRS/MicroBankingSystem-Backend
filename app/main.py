from fastapi import FastAPI , Request
from app.api import auth_routes
from app.middleware.auth_middleware import AuthMiddleware
from app.api import test_account_routes
from fastapi.responses import JSONResponse
from app.api import customer_routes
from fastapi.middleware.cors import CORSMiddleware 

from fastapi.openapi.utils import get_openapi
from fastapi.security.api_key import APIKeyHeader
#from fastapi.middleware.cors import CORSMiddleware
app = FastAPI()

origins = [
    "http://localhost:5173",
    "http://127.0.0.1:5173",
]

app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:5173"],  # must match frontend
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)
# Middleware
app.add_middleware(AuthMiddleware)

# Routes
app.include_router(auth_routes.router,prefix="/api/auth",tags=["Authentication"])
app.include_router(test_account_routes.router,prefix="/api/account",tags=["Accounts"])









app.include_router(customer_routes.router, prefix="/customer_data", tags=["Customer Login & get data"])


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













#this below this lines, just I (sangeeth) added to the auth process with fast api ui swagger, so no need to worry with this

# Define the header for Swagger
api_key_header = APIKeyHeader(name="Authorization", auto_error=False)

# Override OpenAPI to show Authorize button
def custom_openapi():
    if app.openapi_schema:
        return app.openapi_schema
    openapi_schema = get_openapi(
        title="Banking API - From TEAM SMTDS",
        version="1.0.0",
        description="API for Banking System",
        routes=app.routes,
    )
    # Add API Key security scheme
    openapi_schema["components"]["securitySchemes"] = {
        "BearerAuth": {
            "type": "apiKey",
            "name": "Authorization",
            "in": "header"
        }
    }
    # Apply globally to all endpoints
    for path in openapi_schema["paths"].values():
            for method in path.values():
                method.setdefault("security", [{"BearerAuth": []}])

    app.openapi_schema = openapi_schema
    return app.openapi_schema

app.openapi = custom_openapi




@app.exception_handler(404)
async def not_found_handler(request: Request, exc):
    return JSONResponse(
        status_code=404,
        content={"error": "Route not found. Please check the URL."}
    )