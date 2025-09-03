 # manage accounts (create/view)

from fastapi import APIRouter

router = APIRouter()


@router.get("/my_profile")
def my_profile():
    return {"message": "My Profile"}