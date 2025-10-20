import uuid
from fastapi import APIRouter, Depends, HTTPException, Query, Request
from app.schemas.transaction_management_schema import (
    DepositRequest, WithdrawRequest, TransferRequest, TransactionResponse, TransactionStatusResponse,
    AccountTransactionHistory, DateRangeRequest, DateRangeTransactionResponse,
    BranchReportRequest, BranchTransactionSummary, TransactionSummaryRequest,
    AccountTransactionSummary, TransactionAnalytics, TransactionType, AccountBalanceResponse
)
from app.database.db import get_db
from app.repositories.transaction_management_repo import TransactionManagementRepository
from app.services.transaction_management_service import TransactionManagementService
from app.repositories.user_repo import UserRepository
from typing import Optional
from datetime import date

router = APIRouter()

def get_transaction_service(db=Depends(get_db)) -> TransactionManagementService:
    """Dependency to get transaction management service"""
    transaction_repo = TransactionManagementRepository(db)
    return TransactionManagementService(transaction_repo)

def get_current_user(request: Request):
    """Simple dependency to get current authenticated user from request state"""
    if not hasattr(request.state, 'user') or not request.state.user:
        raise HTTPException(status_code=401, detail="Authentication required")
    return request.state.user

# Core transaction endpoints
@router.post("/deposit", response_model=TransactionStatusResponse)
def process_deposit(
    request: DepositRequest,
    current_user: dict = Depends(get_current_user),
    transaction_service: TransactionManagementService = Depends(get_transaction_service)
):
    """
    Process a deposit transaction
    
    - **account_no**: Account number to deposit funds to
    - **amount**: Amount to deposit (must be greater than 0)
    - **description**: Optional description for the transaction
    
    Returns transaction status with auto-generated transaction_id and reference_no
    """
    user_id = current_user.get('user_id')
    return transaction_service.process_deposit(request, user_id)

@router.post("/withdraw", response_model=TransactionStatusResponse)
def process_withdrawal(
    request: WithdrawRequest,
    current_user: dict = Depends(get_current_user),
    transaction_service: TransactionManagementService = Depends(get_transaction_service)
):
    """
    Process a withdrawal transaction
    
    - **account_no**: Account number to withdraw funds from
    - **amount**: Amount to withdraw (must be greater than 0)
    - **description**: Optional description for the transaction
    
    Returns transaction status with auto-generated transaction_id and reference_no, or error if insufficient funds
    """
    user_id = current_user.get('user_id')
    return transaction_service.process_withdrawal(request, user_id)

@router.post("/transfer", response_model=TransactionStatusResponse)
def process_transfer(
    request: TransferRequest,
    current_user: dict = Depends(get_current_user),
    transaction_service: TransactionManagementService = Depends(get_transaction_service)
):
    """
    Process a money transfer between two accounts
    
    - **from_account_no**: Account number to transfer money from
    - **to_account_no**: Account number to transfer money to
    - **amount**: Amount to transfer (must be greater than 0)
    - **description**: Optional description for the transfer
    
    Returns transaction status with auto-generated transaction_id and reference_no, or error if insufficient funds or invalid accounts
    """
    user_id = current_user.get('user_id')
    return transaction_service.process_transfer(request, user_id)

# Transaction history and retrieval endpoints
@router.get("/account/{account_no}", response_model=AccountTransactionHistory)
def get_account_transactions(
    account_no: int,
    current_user: dict = Depends(get_current_user),
    page: int = Query(1, ge=1, description="Page number (starts from 1)"),
    per_page: int = Query(50, ge=1, le=100, description="Number of transactions per page (max 100)"),
    transaction_service: TransactionManagementService = Depends(get_transaction_service)
):
    """
    Get transaction history for a specific account
    
    - **account_no**: Account Number to get transactions for
    - **page**: Page number (optional, defaults to 1)
    - **per_page**: Number of transactions per page (optional, defaults to 50, max 100)
    
    Returns paginated list of transactions with account balance
    """
    return transaction_service.get_account_transactions_by_account_no(account_no, page, per_page)

@router.get("/transaction/{transaction_id}", response_model=TransactionResponse)
def get_transaction_details(
    transaction_id: str,
    current_user: dict = Depends(get_current_user),
    transaction_service: TransactionManagementService = Depends(get_transaction_service)
):
    """
    Get details of a specific transaction
    
    - **transaction_id**: Transaction ID to get details for
    
    Returns complete transaction information
    """
    return transaction_service.get_transaction_by_id(transaction_id)

# Date range and reporting endpoints
@router.get("/report/date-range", response_model=DateRangeTransactionResponse)
def get_transactions_by_date_range(
    request: DateRangeRequest,
    current_user: dict = Depends(get_current_user),
    transaction_service: TransactionManagementService = Depends(get_transaction_service)
):
    """
    Get transactions within a date range
    
    - **start_date**: Start date for the range (YYYY-MM-DD)
    - **end_date**: End date for the range (YYYY-MM-DD)
    - **acc_id**: Optional account ID filter
    - **transaction_type**: Optional transaction type filter
    
    Returns transactions with summary statistics
    """
    return transaction_service.get_transactions_by_date_range(request)

@router.get("/report/branch/{branch_id}", response_model=BranchTransactionSummary)
def get_branch_transaction_report(
    branch_id: str,
    start_date: date = Query(..., description="Start date for the report (YYYY-MM-DD)"),
    end_date: date = Query(..., description="End date for the report (YYYY-MM-DD)"),
    transaction_type: Optional[str] = Query(None, description="Optional transaction type filter"),
    current_user: dict = Depends(get_current_user),
    transaction_service: TransactionManagementService = Depends(get_transaction_service)
):
    """
    Get transaction report for a specific branch
    
    - **branch_id**: Branch ID for the report
    - **start_date**: Start date for the report
    - **end_date**: End date for the report
    - **transaction_type**: Optional transaction type filter
    
    Returns comprehensive branch transaction summary with top accounts
    """
    # Convert string to enum if provided
    tx_type = None
    if transaction_type:
        try:
            tx_type = TransactionType(transaction_type)
        except ValueError:
            raise HTTPException(status_code=400, detail=f"Invalid transaction type: {transaction_type}")
    
    request = BranchReportRequest(
        branch_id=branch_id,
        start_date=start_date,
        end_date=end_date,
        transaction_type=tx_type
    )
    
    return transaction_service.get_branch_transaction_report(request)

# Transaction summary endpoints
@router.get("/summary/{account_no}", response_model=AccountTransactionSummary)
def get_account_transaction_summary(
    account_no: int,
    period: str = Query("monthly", description="Summary period (daily, weekly, monthly, yearly)"),
    start_date: Optional[date] = Query(None, description="Optional start date"),
    end_date: Optional[date] = Query(None, description="Optional end date"),
    current_user: dict = Depends(get_current_user),
    transaction_service: TransactionManagementService = Depends(get_transaction_service)
):
    """
    Get transaction summary for an account
    
    - **account_no**: Account number for summary
    - **period**: Summary period (daily, weekly, monthly, yearly)
    - **start_date**: Optional start date filter
    - **end_date**: Optional end date filter
    
    Returns aggregated transaction data by the specified period
    """
    # Validate period manually
    if period not in ["daily", "weekly", "monthly", "yearly"]:
        raise HTTPException(status_code=400, detail="Period must be one of: daily, weekly, monthly, yearly")
    
    # Get acc_id from account_no
    acc_id = transaction_service.transaction_repo.get_account_id_by_account_no(account_no)
    if not acc_id:
        raise HTTPException(status_code=404, detail=f"Account with number {account_no} not found")
    
    request = TransactionSummaryRequest(
        acc_id=acc_id,
        period=period,
        start_date=start_date,
        end_date=end_date
    )
    
    return transaction_service.get_transaction_summary(request)

# Analytics endpoints
@router.get("/analytics/{account_no}", response_model=TransactionAnalytics)
def get_transaction_analytics(
    account_no: int,
    days: int = Query(30, ge=1, le=365, description="Number of days to analyze (max 365)"),
    current_user: dict = Depends(get_current_user),
    transaction_service: TransactionManagementService = Depends(get_transaction_service)
):
    """
    Get detailed analytics for an account
    
    - **account_no**: Account number for analytics
    - **days**: Number of days to analyze (optional, defaults to 30, max 365)
    
    Returns comprehensive transaction analytics including patterns and statistics
    """
    # Get acc_id from account_no
    acc_id = transaction_service.transaction_repo.get_account_id_by_account_no(account_no)
    if not acc_id:
        raise HTTPException(status_code=404, detail=f"Account with number {account_no} not found")
        
    return transaction_service.get_transaction_analytics(acc_id, days)

# Account balance endpoint
@router.get("/account/{account_no}/balance", response_model=AccountBalanceResponse)
def get_account_balance(
    account_no: int,
    current_user: dict = Depends(get_current_user),
    transaction_service: TransactionManagementService = Depends(get_transaction_service)
):
    """
    Get current balance for an account
    
    - **account_no**: Account Number to get balance for
    
    Returns current account balance
    """
    try:
        transaction_repo = TransactionManagementRepository(transaction_service.transaction_repo.conn)
        
        # Debug: Check what accounts exist (using correct column names)
        transaction_repo.cursor.execute("""
            SELECT a.acc_id, a.account_no, a.balance, c.full_name as customer_name
            FROM account a
            LEFT JOIN accounts_owner ao ON a.acc_id = ao.acc_id
            LEFT JOIN customer c ON ao.customer_id = c.customer_id
            LIMIT 5
        """)
        available_accounts = transaction_repo.cursor.fetchall()
        
        # Get account details with customer name using account_no
        transaction_repo.cursor.execute("""
            SELECT 
                a.acc_id, 
                a.account_no, 
                a.balance,
                c.full_name as account_holder_name
            FROM account a
            LEFT JOIN accounts_owner ao ON a.acc_id = ao.acc_id
            LEFT JOIN customer c ON ao.customer_id = c.customer_id
            WHERE a.account_no = %s
        """, (account_no,))
        
        account_details = transaction_repo.cursor.fetchone()
        
        if not account_details:
            return {
                "error": "Account not found",
                "provided_account_no": account_no,
                "available_accounts": [dict(acc) for acc in available_accounts],
                "message": "Use one of the available account numbers above"
            }
        
        balance = account_details['balance']
        if balance is None:
            # Try to fix NULL balance by setting it to 0.00
            transaction_repo.cursor.execute("""
                UPDATE account SET balance = 0.00 WHERE account_no = %s
            """, (account_no,))
            transaction_repo.conn.commit()
            balance = 0.00
            return AccountBalanceResponse(
                acc_id=account_details['acc_id'],
                account_no=account_details['account_no'],
                account_holder_name=account_details['account_holder_name'],
                balance=balance,
                message="Balance was NULL, fixed to 0.00 and retrieved successfully"
            )
        
        return AccountBalanceResponse(
            acc_id=account_details['acc_id'],
            account_no=account_details['account_no'],
            account_holder_name=account_details['account_holder_name'],
            balance=float(balance),
            message="Balance retrieved successfully"
        )
    
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to get account balance: {str(e)}")

# Advanced reporting endpoints
@router.get("/report/all-transactions")
def get_all_transactions_report(
    page: int = Query(1, ge=1, description="Page number"),
    per_page: int = Query(100, ge=1, le=500, description="Records per page (max 500)"),
    acc_id: Optional[str] = Query(None, description="Filter by account ID"),
    transaction_type: Optional[str] = Query(None, description="Filter by transaction type"),
    start_date: Optional[date] = Query(None, description="Start date filter"),
    end_date: Optional[date] = Query(None, description="End date filter"),
    transaction_service: TransactionManagementService = Depends(get_transaction_service)
):
    """
    Get comprehensive transaction report with advanced filtering
    
    This endpoint provides detailed transaction data with multiple filter options.
    Useful for administrative reporting and analysis.
    """
    try:
        transaction_repo = TransactionManagementRepository(transaction_service.transaction_repo.conn)
        
        # Calculate offset
        offset = (page - 1) * per_page
        
        # Get filtered transactions
        if start_date and end_date:
            # Use date range query
            date_request = DateRangeRequest(
                start_date=start_date,
                end_date=end_date,
                acc_id=acc_id,
                transaction_type=TransactionType(transaction_type) if transaction_type else None
            )
            result = transaction_service.get_transactions_by_date_range(date_request)
            
            # Filter transactions by date and acc_id in the route for robustness
            filtered_transactions = [
                tx for tx in result.transactions 
                if start_date <= tx.created_at.date() <= end_date
            ]
            if acc_id:
                filtered_transactions = [
                    tx for tx in filtered_transactions 
                    if tx.acc_id == acc_id
                ]
            
            # Remove duplicates based on transaction_id
            unique_transactions = []
            seen_ids = set()
            for tx in filtered_transactions:
                if tx.transaction_id not in seen_ids:
                    unique_transactions.append(tx)
                    seen_ids.add(tx.transaction_id)
            
            result.transactions = unique_transactions
            result.total_count = len(unique_transactions)
            
            return {
                "transactions": result.transactions,
                "total_count": result.total_count,
                "page": page,
                "per_page": per_page,
                "summary": result.summary,
                "filters": {
                    "acc_id": acc_id,
                    "transaction_type": transaction_type,
                    "start_date": start_date.isoformat() if start_date else None,
                    "end_date": end_date.isoformat() if end_date else None
                }
            }
        
        elif acc_id:
            # Use account-specific query
            result = transaction_service.get_account_transactions(acc_id, page, per_page)
            return {
                "transactions": result.transactions,
                "total_count": result.total_count,
                "page": page,
                "per_page": per_page,
                "current_balance": result.current_balance,
                "filters": {
                    "acc_id": acc_id,
                    "transaction_type": transaction_type
                }
            }
        
        else:
            # Get all transactions with pagination and balance_after
            all_transactions = transaction_repo.get_all_transactions_with_balance_after(per_page, offset)
            
            transactions = [
                TransactionResponse(
                    transaction_id=tx['transaction_id'],
                    amount=float(tx['amount']),
                    acc_id=tx['acc_id'],
                    type=tx['type'],
                    description=tx['description'],
                    reference_no=tx['reference_no'],
                    created_at=tx['created_at'],
                    created_by=tx['created_by'],
                    balance_after=float(tx['balance_after']) if tx.get('balance_after') is not None else None
                )
                for tx in all_transactions
            ]
            
            return {
                "transactions": transactions,
                "total_count": len(transactions),
                "page": page,
                "per_page": per_page,
                "message": "All transactions retrieved successfully",
                "filters": {
                    "transaction_type": transaction_type
                }
            }
    
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to get transaction report: {str(e)}")

# =============================================================================
# UUID-BASED APIs (Direct account_id access)
# These APIs work with account_id (UUID) directly, bypassing account_no lookup
# =============================================================================

@router.get("/accounttransactions/{account_id}", response_model=AccountTransactionHistory)
def get_account_transactions_by_uuid(
    account_id: str,
    current_user: dict = Depends(get_current_user),
    page: int = Query(1, ge=1, description="Page number (starts from 1)"),
    per_page: int = Query(50, ge=1, le=100, description="Number of transactions per page (max 100)"),
    transaction_service: TransactionManagementService = Depends(get_transaction_service)
):
    """
    Get transaction history for a specific account using account_id (UUID)
    
    - **account_id**: Account UUID to get transactions for
    - **page**: Page number (optional, defaults to 1)
    - **per_page**: Number of transactions per page (optional, defaults to 50, max 100)
    
    Returns paginated list of transactions with account balance
    """
    return transaction_service.get_account_transactions(account_id, page, per_page)


@router.get("/transactions/branch/{branch_id}")
def get_branch_transactions_report_by_date(
    branch_id: str,
    start_date: date = Query(..., description="Start date for the report (YYYY-MM-DD)"),
    end_date: date = Query(..., description="End date for the report (YYYY-MM-DD)"),
    transaction_type: Optional[str] = Query(None, description="Optional transaction type filter (deposit, withdrawal, transfer)"),
    transaction_service: TransactionManagementService = Depends(get_transaction_service)
):
    """
    Get transaction report for a specific branch within a date range
    
    - **branch_id**: Branch UUID to get transactions for
    - **start_date**: Start date for the report (YYYY-MM-DD)
    - **end_date**: End date for the report (YYYY-MM-DD)
    - **transaction_type**: Optional transaction type filter (deposit, withdrawal, transfer)
    
    Returns:
    - List of all transactions for accounts in the branch
    - Summary statistics including total transactions and amounts
    - Breakdown by transaction type
    """
    return transaction_service.get_branch_transactions_report(branch_id, start_date, end_date, transaction_type)



@router.get("/transactions/users_branch")
def get_users_branch_transactions(
    request: Request,
    start_date: date = Query(..., description="Start date for the report (YYYY-MM-DD)"),
    end_date: date = Query(..., description="End date for the report (YYYY-MM-DD)"),
    transaction_type: Optional[str] = Query(None, description="Optional transaction type filter (deposit, withdrawal, transfer)"),
    current_user: dict = Depends(get_current_user),
    transaction_service: TransactionManagementService = Depends(get_transaction_service)
):
    """
    Get transaction report for the branch of the authenticated user within a date range
    
    - **start_date**: Start date for the report (YYYY-MM-DD)
    - **end_date**: End date for the report (YYYY-MM-DD)
    - **transaction_type**: Optional transaction type filter (deposit, withdrawal, transfer)
    
    Returns:
    - List of all transactions for accounts in the user's branch
    - Summary statistics including total transactions and amounts
    - Breakdown by transaction type
    """
    return transaction_service.get_users_branch_transactions_report(current_user, start_date, end_date)

@router.get("transactions/{account_no}/summery_with_history", response_model=dict)
def get_transaction_summary_with_history(
    account_no: int,
    start_date: Optional[date] = Query(None, description="Optional start date filter (YYYY-MM-DD)"),
    end_date: Optional[date] = Query(None, description="Optional end date filter (YYYY-MM-DD)"),
    transaction_service: TransactionManagementService = Depends(get_transaction_service)
):
    """
    Get transaction summary along with complete transaction history for an account
    
    - **account_no**: Account number for summary and history
    - **start_date**: Optional start date to filter transactions (YYYY-MM-DD)
    - **end_date**: Optional end date to filter transactions (YYYY-MM-DD)
    
    Returns:
    - Account information (account_no, acc_id, current_balance)
    - Aggregated transaction summary statistics
    - Complete list of all transactions for the account (filtered by date if provided)
    """
    try:
        # Validate date range if both provided
        if start_date and end_date and start_date > end_date:
            raise HTTPException(status_code=400, detail="Start date must be before or equal to end date")
        
        # Get acc_id from account_no
        acc_id = transaction_service.transaction_repo.get_account_id_by_account_no(account_no)
        if not acc_id:
            raise HTTPException(status_code=404, detail=f"Account with number {account_no} not found")
        
        # Get summary with all history (with optional date filtering)
        result = transaction_service.get_transaction_with_summary(
            acc_id=acc_id,
            start_date=start_date,
            end_date=end_date
        )
        
        return {
            "success": True,
            "data": result,
            "message": "Transaction summary with complete history retrieved successfully",
            "filters": {
                "start_date": start_date.isoformat() if start_date else None,
                "end_date": end_date.isoformat() if end_date else None
            }
        }
    
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to retrieve transaction summary: {str(e)}")