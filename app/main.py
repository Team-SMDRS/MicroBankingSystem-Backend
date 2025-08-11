from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from .middleware.custom_middleware import CustomMiddleware
from .routers import customer ,user  # your existing router import

app = FastAPI()

# Add built-in CORS middleware (optional)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # change to your allowed origins
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Add your custom middleware
app.add_middleware(CustomMiddleware)

# Include your routers
app.include_router(customer.router)
app.include_router(user.router)