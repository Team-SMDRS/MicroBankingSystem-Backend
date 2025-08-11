from fastapi import APIRouter

# Create router instance
router = APIRouter(
    prefix="/users",
    tags=["users"]
)

# Sample users data (in-memory for now)
fake_users = [
    {"id": 1, "name": "John Doe", "email": "john@example.com"},
    {"id": 2, "name": "Jane Smith", "email": "jane@example.com"}
]

@router.get("/")
async def get_users():
    """Get all users"""
    return {"users": fake_users}

@router.get("/{user_id}")
async def get_user(user_id: int):
    """Get user by ID"""
    user = next((user for user in fake_users if user["id"] == user_id), None)
    if user:
        return {"user": user}
    return {"message": "User not found"}

@router.post("/")
async def create_user(name: str, email: str):
    """Create a new user"""
    new_user = {
        "id": len(fake_users) + 1,
        "name": name,
        "email": email
    }
    fake_users.append(new_user)
    return {"message": "User created", "user": new_user}