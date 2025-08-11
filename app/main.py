from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from app.routes import user_routes

# Create FastAPI instance
app = FastAPI(
    title="My FastAPI Project",
    description="A simple FastAPI application",
    version="1.0.0"
)

# Add CORS middleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Include routers
app.include_router(user_routes.router)

# Root endpoint
@app.get("/")
async def root():
    return {"message": "Hello World! FastAPI is working!"}

# Health check endpoint
@app.get("/health")
async def health_check():
    return {"status": "healthy"}

# Simple test endpoint
@app.get("/test/{item_id}")
async def read_item(item_id: int, q: str = None):
    return {"item_id": item_id, "q": q}