from fastapi import APIRouter, Depends, Request
from app.middleware.require_permission import require_permission
from app.database.db import get_db
from app.repositories.savings_plan_repo import SavingsPlanRepository
from app.services.savings_plan_service import SavingsPlanService
from app.schemas.savings_plan_schema import SavingsPlanCreate

router = APIRouter()


# Route to create a new savings plan
@router.post("/savings_plan/create")
@require_permission("admin")
def create_savings_plan(plan: SavingsPlanCreate, request: Request, db=Depends(get_db)):
    repo = SavingsPlanRepository(db)
    service = SavingsPlanService(repo)
    current_user = getattr(request.state, "user", None)
    if not current_user or "user_id" not in current_user:
        return {"detail": "Authentication required to create a savings plan."}
    plan_data = plan.dict()
    plan_data["user_id"] = current_user["user_id"]
    result = service.create_savings_plan(plan_data)
    if "error" in result:
        return {"detail": result["error"]}
    return result

# Route to update a savings plan's interest rate
@router.put("/savings_plan/{savings_plan_id}/interest_rate")
@require_permission("admin")
def update_savings_plan_interest_rate(savings_plan_id: str, new_interest_rate: float, request: Request, db=Depends(get_db)):
    repo = SavingsPlanRepository(db)
    service = SavingsPlanService(repo)
    current_user = getattr(request.state, "user", None)
    if not current_user or "user_id" not in current_user:
        return {"detail": "Authentication required to update a savings plan."}
    updated = service.update_savings_plan(savings_plan_id, new_interest_rate, current_user["user_id"])
    if not updated:
        return {"detail": "Savings plan not found or not updated."}
    return updated


# Route to list all savings plans (id and name)
@router.get("/savings_plans")
@require_permission("agent")
def list_savings_plans(request: Request, db=Depends(get_db)):
    repo = SavingsPlanRepository(db)
    service = SavingsPlanService(repo)
    # No auth required for listing, but you can enforce if needed
    plans = service.get_all_savings_plans()
    # Return as a list of dicts
    return {"savings_plans": plans}


# Route to list all savings plans with details (id, name, interest_rate, minimum_balance)
@router.get("/savings_plans/details")
@require_permission("agent")
def list_savings_plan_details(request: Request, db=Depends(get_db)):
    repo = SavingsPlanRepository(db)
    service = SavingsPlanService(repo)
    plans = service.get_all_savings_plan_details()
    return {"savings_plans": plans}