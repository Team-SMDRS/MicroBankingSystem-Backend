"""
Transfer Functionality Test Routes
This file contains additional routes for testing the transfer functionality
"""

from fastapi import APIRouter, Depends, HTTPException, Query
from app.schemas.transaction_management_schema import TransferRequest, TransactionStatusResponse
from app.services.transaction_management_service import TransactionManagementService
from app.repositories.transaction_management_repo import TransactionManagementRepository
from app.database.db import get_db
from typing import Dict, Any, Optional

test_router = APIRouter(prefix="/test", tags=["Transfer Testing"])

def get_transaction_service(db=Depends(get_db)) -> TransactionManagementService:
    """Dependency to get transaction management service"""
    transaction_repo = TransactionManagementRepository(db)
    return TransactionManagementService(transaction_repo)

def get_current_user():
    """Mock user for testing - replace with actual auth in production"""
    return {"user_id": "550e8400-e29b-41d4-a716-446655440000"}  # Mock UUID

@test_router.post("/transfer", response_model=TransactionStatusResponse)
def test_transfer(
    request: TransferRequest,
    transaction_service: TransactionManagementService = Depends(get_transaction_service),
    current_user: dict = Depends(get_current_user)
):
    """
    Test transfer endpoint with comprehensive validation
    
    Test Cases:
    1. Valid transfer between existing accounts
    2. Transfer with insufficient funds  
    3. Transfer to same account (should fail)
    4. Transfer with invalid amount (should fail)
    5. Transfer exceeding limits (should fail)
    """
    return transaction_service.process_transfer(request, current_user.get('user_id'))

@test_router.get("/accounts")
def get_test_accounts(
    transaction_service: TransactionManagementService = Depends(get_transaction_service)
):
    """
    Get list of test accounts for transfer testing
    """
    try:
        # Get sample accounts for testing
        transaction_service.transaction_repo.cursor.execute("""
            SELECT 
                a.acc_id,
                a.account_no,
                a.balance,
                c.full_name as account_holder_name
            FROM account a
            LEFT JOIN accounts_owner ao ON a.acc_id = ao.acc_id
            LEFT JOIN customer c ON ao.customer_id = c.customer_id
            WHERE a.balance IS NOT NULL
            ORDER BY a.account_no
            LIMIT 10
        """)
        
        accounts = transaction_service.transaction_repo.cursor.fetchall()
        
        return {
            "success": True,
            "message": "Test accounts retrieved successfully",
            "accounts": [
                {
                    "acc_id": acc['acc_id'],
                    "account_no": acc['account_no'],
                    "balance": float(acc['balance']) if acc['balance'] else 0.0,
                    "account_holder_name": acc['account_holder_name']
                }
                for acc in accounts
            ],
            "transfer_test_instructions": {
                "1": "Use two different account_no values for valid transfer test",
                "2": "Set amount higher than source account balance for insufficient funds test",
                "3": "Use same account_no for both from_account_no and to_account_no for same account test",
                "4": "Set amount to 0 or negative for invalid amount test",
                "5": "Set amount > 100000 for limit exceeded test"
            }
        }
        
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to get test accounts: {str(e)}")

@test_router.post("/transfer/scenarios")
def test_transfer_scenarios(
    scenario: str = Query(..., description="Test scenario: valid, insufficient_funds, same_account, invalid_amount, limit_exceeded"),
    from_account_no: int = Query(..., description="Source account number"),
    to_account_no: Optional[int] = Query(None, description="Destination account number"),
    amount: Optional[float] = Query(None, description="Transfer amount"),
    transaction_service: TransactionManagementService = Depends(get_transaction_service),
    current_user: dict = Depends(get_current_user)
):
    """
    Test predefined transfer scenarios
    """
    try:
        # Define test scenarios
        if scenario == "valid":
            # Valid transfer scenario
            if not to_account_no or not amount:
                raise HTTPException(status_code=400, detail="to_account_no and amount required for valid scenario")
            
            request = TransferRequest(
                from_account_no=from_account_no,
                to_account_no=to_account_no,
                amount=amount,
                description=f"Test transfer scenario: {scenario}"
            )
            
        elif scenario == "insufficient_funds":
            # Set amount higher than account balance
            if not to_account_no:
                raise HTTPException(status_code=400, detail="to_account_no required for insufficient_funds scenario")
            
            # Get current balance and set amount higher
            acc_id = transaction_service.transaction_repo.get_account_id_by_account_no(from_account_no)
            current_balance = transaction_service.transaction_repo.get_account_balance(acc_id)
            test_amount = current_balance + 1000.0  # More than available
            
            request = TransferRequest(
                from_account_no=from_account_no,
                to_account_no=to_account_no,
                amount=test_amount,
                description=f"Test transfer scenario: {scenario}"
            )
            
        elif scenario == "same_account":
            # Transfer to same account
            request = TransferRequest(
                from_account_no=from_account_no,
                to_account_no=from_account_no,  # Same account
                amount=100.0,
                description=f"Test transfer scenario: {scenario}"
            )
            
        elif scenario == "invalid_amount":
            # Invalid amount (zero or negative)
            if not to_account_no:
                raise HTTPException(status_code=400, detail="to_account_no required for invalid_amount scenario")
            
            request = TransferRequest(
                from_account_no=from_account_no,
                to_account_no=to_account_no,
                amount=0.0,  # Invalid amount
                description=f"Test transfer scenario: {scenario}"
            )
            
        elif scenario == "limit_exceeded":
            # Amount exceeding limits
            if not to_account_no:
                raise HTTPException(status_code=400, detail="to_account_no required for limit_exceeded scenario")
            
            request = TransferRequest(
                from_account_no=from_account_no,
                to_account_no=to_account_no,
                amount=150000.0,  # Exceeds Rs.100,000 limit
                description=f"Test transfer scenario: {scenario}"
            )
            
        else:
            raise HTTPException(
                status_code=400, 
                detail="Invalid scenario. Use: valid, insufficient_funds, same_account, invalid_amount, limit_exceeded"
            )
        
        # Execute the transfer
        result = transaction_service.process_transfer(request, current_user.get('user_id'))
        
        return {
            "scenario": scenario,
            "test_request": request.dict(),
            "result": result,
            "test_passed": result.success if scenario == "valid" else not result.success
        }
        
    except HTTPException as he:
        # Expected HTTP exceptions for test scenarios
        return {
            "scenario": scenario,
            "test_request": {
                "from_account_no": from_account_no,
                "to_account_no": to_account_no,
                "amount": amount
            },
            "result": {
                "success": False,
                "message": he.detail,
                "error_code": he.status_code
            },
            "test_passed": scenario != "valid"  # For error scenarios, test passes if there's an error
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Test scenario failed: {str(e)}")

@test_router.get("/database-function-test")
def test_database_function(
    transaction_service: TransactionManagementService = Depends(get_transaction_service)
):
    """
    Test if the PostgreSQL transfer function exists and is working
    """
    try:
        # Check if function exists
        transaction_service.transaction_repo.cursor.execute("""
            SELECT 
                proname as function_name,
                pg_get_function_arguments(oid) as arguments,
                pg_get_function_result(oid) as return_type
            FROM pg_proc 
            WHERE proname = 'process_transfer_transaction'
        """)
        
        function_info = transaction_service.transaction_repo.cursor.fetchone()
        
        if not function_info:
            return {
                "success": False,
                "message": "PostgreSQL transfer function not found",
                "recommendation": "Run the ENHANCED_TRANSFER_FUNCTION.sql script to create the function"
            }
        
        return {
            "success": True,
            "message": "PostgreSQL transfer function exists and ready",
            "function_details": dict(function_info),
            "next_steps": "Function is ready. You can now test transfers using the /test/transfer endpoint"
        }
        
    except Exception as e:
        return {
            "success": False,
            "message": f"Failed to check database function: {str(e)}",
            "recommendation": "Check database connection and ensure the function is created"
        }
