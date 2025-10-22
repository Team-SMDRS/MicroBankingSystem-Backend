"""
Simple Transaction Report API
"""


from re import I
from webbrowser import get
from fastapi import APIRouter, Depends, Request, HTTPException
from pydantic import BaseModel
from app.middleware.require_permission import require_permission
from app.services import customer_service, overview_services
from app.services.pdf_report_service import PDFReportService
from fastapi.responses import StreamingResponse
from app.database.db import get_db
from app.middleware.customer_middleware import customer_auth_dependency
router = APIRouter()


class SimplePDFRequest(BaseModel):
    """Minimal PDF request"""
    branch_name: str
    total_deposits: float
    total_withdrawals: float


@router.get("/users/report/pdf", tags=["PDF Reports"])
@require_permission("agent")
async def get_own_users_transaction_report_pdf(request: Request, db=Depends(get_db)):
    """Generate PDF report for the authenticated users transactions."""
    user = getattr(request.state, "user", None)
    user_id = user["user_id"] if user and "user_id" in user else None
    try:
        pdf_service = PDFReportService(db)
        pdf_buffer = pdf_service.generate_users_all_transaction_report_by_id(user_id=user_id)

        filename = f"report.pdf"
        return StreamingResponse(
            iter([pdf_buffer.getvalue()]),
            media_type="application/pdf",
            headers={"Content-Disposition": f"attachment; filename={filename}"}
        )
    except Exception as e:
        return {"error": str(e)}


@router.get("/admin/users/{user_id}/report/pdf", tags=["PDF Reports"])
@require_permission("admin")
async def get_admin_users_all_transaction_report_pdf(user_id: str, request: Request, db=Depends(get_db)):
    """Generate PDF report for a specific user's transactions (admin)."""
    try:
        pdf_service = PDFReportService(db)
        pdf_buffer = pdf_service.generate_users_all_transaction_report_by_id(user_id=user_id)

        filename = f"report_{user_id}.pdf"
        return StreamingResponse(
            iter([pdf_buffer.getvalue()]),
            media_type="application/pdf",
            headers={"Content-Disposition": f"attachment; filename={filename}"}
        )
    except Exception as e:
        return {"error": str(e)}
    


@router.get("/users/transaction/today_report", tags=["PDF Reports"])
@require_permission("agent")
async def get_own_users_today_transaction_report_pdf(request: Request, db=Depends(get_db)):
    """Generate PDF report for the authenticated users today's transactions."""
    user = getattr(request.state, "user", None)
    user_id = user["user_id"] if user and "user_id" in user else None
    try:
        pdf_service = PDFReportService(db)
        pdf_buffer = pdf_service.generate_users_today_transaction_report_with_summary(user_id=user_id)

        filename = f"today_report.pdf"
        return StreamingResponse(
            iter([pdf_buffer.getvalue()]),
            media_type="application/pdf",
            headers={"Content-Disposition": f"attachment; filename={filename}"}
        )
    except Exception as e:
        return {"error": str(e)}
    


@router.get("/admin/daily_transactions_by_branch/report/pdf", tags=["PDF Reports"])
@require_permission("admin")
async def get_admin_daily_transactions_by_branch_report_pdf(branch_id: str, start_date: str, end_date: str, request: Request, db=Depends(get_db)):
    """Generate PDF report for daily transactions by branch (admin)."""
    try:
        pdf_service = PDFReportService(db)
        pdf_buffer = pdf_service.generate_date_range_transactions_report_by_branch(branch_id=branch_id, start_date=start_date, end_date=end_date)

        filename = f"daily_transactions_branch_{branch_id}.pdf"
        return StreamingResponse(
            iter([pdf_buffer.getvalue()]),
            media_type="application/pdf",
            headers={"Content-Disposition": f"attachment; filename={filename}"}
        )
    except Exception as e:
        return {"error": str(e)}
    

@router.get("/users/daily_branch_transactions/report/pdf", tags=["PDF Reports"])
@require_permission("manager")
async def get_users_daily_branch_transactions_report_pdf(start_date: str, end_date: str, request: Request, db=Depends(get_db)):
    """Generate PDF report for daily branch transactions for the authenticated user."""
  
    # Get branch_id from request.state (set by middleware)
    user = getattr(request.state, "user", None)
    branch_id = user["branch_id"] if user and "branch_id" in user else None

    try:
        pdf_service = PDFReportService(db)
        pdf_buffer = pdf_service.generate_date_range_transactions_report_by_branch(branch_id=branch_id, start_date=start_date, end_date=end_date)

        filename = f"daily_transactions_branch_{branch_id}.pdf"
        return StreamingResponse(
            iter([pdf_buffer.getvalue()]),
            media_type="application/pdf",
            headers={"Content-Disposition": f"attachment; filename={filename}"}
        )
    except Exception as e:
        return {"error": str(e)}
    

@router.get("/admin/daily_customer_transactions_report/{customer_id}/pdf", tags=["PDF Reports"])
@require_permission("admin")
async def get_admin_daily_customer_transactions_report_pdf(
    customer_id: str, 
    start_date: str, 
    end_date: str, 
    request: Request,
    db=Depends(get_db)
):
    """
    Generate PDF report for customer transactions within a date range (admin).
    
    Args:
        customer_id: UUID of the customer
        start_date: Start date in format YYYY-MM-DD
        end_date: End date in format YYYY-MM-DD
    
    Returns:
        PDF file with customer transaction report
    """
    from datetime import datetime
    from fastapi import HTTPException
    
    try:
        # Validate date format
        try:
            start_dt = datetime.strptime(start_date, '%Y-%m-%d')
            end_dt = datetime.strptime(end_date, '%Y-%m-%d')
        except ValueError:
            raise HTTPException(
                status_code=400, 
                detail="Invalid date format. Please use YYYY-MM-DD format."
            )
        
        # Validate date range
        if start_dt > end_dt:
            raise HTTPException(
                status_code=400, 
                detail="Start date cannot be after end date."
            )
        
        # Generate PDF report
        pdf_service = PDFReportService(db)
        pdf_buffer = pdf_service.generate_date_range_transactions_report_by_customer(
            customer_id=customer_id, 
            start_date=start_date, 
            end_date=end_date
        )

        filename = f"customer_transactions_{customer_id}_{start_date}_to_{end_date}.pdf"
        return StreamingResponse(
            iter([pdf_buffer.getvalue()]),
            media_type="application/pdf",
            headers={
                "Content-Disposition": f"attachment; filename={filename}",
                "Content-Type": "application/pdf"
            }
        )
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=f"Failed to generate PDF report: {str(e)}"
        )


@router.get("/customers/my_transactions_report/pdf", tags=["PDF Reports"], dependencies=[Depends(customer_auth_dependency)])
async def get_customer_own_transactions_report_pdf(
    request: Request,
    start_date: str, 
    end_date: str, 
    db=Depends(get_db)
    
):
    """
    Generate PDF report for authenticated customer's transactions within a date range.
    Requires customer authentication.
    
    Args:
        start_date: Start date in format YYYY-MM-DD
        end_date: End date in format YYYY-MM-DD
    
    Returns:
        PDF file with customer transaction report
    
    Note: This endpoint should be accessed via /customer_data/my_transactions_report/pdf
    and requires customer Bearer token authentication.
    """
    from datetime import datetime
    from fastapi import HTTPException
    
    try:
        # Get customer_id from authenticated token (set by customer_auth_dependency middleware)
        customer = getattr(request.state, "customer", None)
        customer_id = customer.get("customer_id") if customer else None
        
        if not customer_id:
            raise HTTPException(
                status_code=401, 
                detail="Customer authentication required. Please login as a customer first."
            )
        
        # Validate date format
        try:
            start_dt = datetime.strptime(start_date, '%Y-%m-%d')
            end_dt = datetime.strptime(end_date, '%Y-%m-%d')
        except ValueError:
            raise HTTPException(
                status_code=400, 
                detail="Invalid date format. Please use YYYY-MM-DD format."
            )
        
        # Validate date range
        if start_dt > end_dt:
            raise HTTPException(
                status_code=400, 
                detail="Start date cannot be after end date."
            )
        
        # Generate PDF report
        pdf_service = PDFReportService(db)
        pdf_buffer = pdf_service.generate_date_range_transactions_report_by_customer(
            customer_id=customer_id, 
            start_date=start_date, 
            end_date=end_date
        )

        filename = f"my_transactions_{start_date}_to_{end_date}.pdf"
        return StreamingResponse(
            iter([pdf_buffer.getvalue()]),
            media_type="application/pdf",
            headers={
                "Content-Disposition": f"attachment; filename={filename}",
                "Content-Type": "application/pdf"
            }
        )
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=f"Failed to generate PDF report: {str(e)}"
        )


@router.get("/admin/accountwise_transactions_report/pdf", tags=["PDF Reports"])
@require_permission("admin")
async def get_admin_accountwise_transactions_report_pdf(
    request: Request,
    account_number: str, 
    start_date: str = None, 
    end_date: str = None, 
    db=Depends(get_db)
):
    """
    Generate PDF report for account transactions within a date range (admin).
    
    Args:
        account_number: Account number to generate report for
        start_date: Optional start date in format YYYY-MM-DD (defaults to account creation date)
        end_date: Optional end date in format YYYY-MM-DD (defaults to today)
    
    Returns:
        PDF file with account transaction report
    """
    from datetime import datetime, date
    from fastapi import HTTPException
    from psycopg2.extras import RealDictCursor
    
    try:
        # Validate account_number format (should be numeric)
        try:
            account_num_int = int(account_number)
        except ValueError:
            raise HTTPException(
                status_code=400, 
                detail="Invalid account number format. Account number must be numeric."
            )
        
        # Handle optional dates
        today = date.today()
        
        # If start_date not provided, get account creation date
        if not start_date:
            # Query to get account creation date
            cursor = db.cursor(cursor_factory=RealDictCursor)
            cursor.execute(
                "SELECT opened_date FROM account WHERE account_no = %s",
                (account_number,)
            )
            account_data = cursor.fetchone()
            if not account_data:
                raise HTTPException(
                    status_code=404, 
                    detail=f"Account with number {account_number} not found."
                )
            start_date = account_data['opened_date'].strftime('%Y-%m-%d')
        
        # If end_date not provided, use today
        if not end_date:
            end_date = today.strftime('%Y-%m-%d')
        
        # Validate date format
        try:
            start_dt = datetime.strptime(start_date, '%Y-%m-%d').date()
            end_dt = datetime.strptime(end_date, '%Y-%m-%d').date()
        except ValueError:
            raise HTTPException(
                status_code=400, 
                detail="Invalid date format. Please use YYYY-MM-DD format."
            )
        
        # Validate date range
        if start_dt > end_dt:
            raise HTTPException(
                status_code=400, 
                detail="Start date cannot be after end date."
            )
        
        # Generate PDF report
        pdf_service = PDFReportService(db)
        pdf_buffer = pdf_service.generate_date_range_transactions_report_by_account(
            account_number=account_number, 
            start_date=start_date, 
            end_date=end_date
        )

        filename = f"account_transactions_{account_number}_{start_date}_to_{end_date}.pdf"
        return StreamingResponse(
            iter([pdf_buffer.getvalue()]),
            media_type="application/pdf",
            headers={
                "Content-Disposition": f"attachment; filename={filename}",
                "Content-Type": "application/pdf"
            }
        )
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=f"Failed to generate PDF report: {str(e)}"
        )



@router.get("/admin/list_active_fd_with_next_payment_date/pdf", tags=["PDF Reports"])
@require_permission("admin")
async def get_list_active_fd_with_next_payment_date_pdf(
    request: Request,
    db=Depends(get_db)
):
    """Generate PDF report listing all active fixed deposits with their next interest payment date (admin)."""
    try:
        pdf_service = PDFReportService(db)
        pdf_buffer = pdf_service.generate_active_fd_with_next_interest_payment_date_report()

        filename = f"active_fd_next_interest_payment_date_report.pdf"
        return StreamingResponse(
            iter([pdf_buffer.getvalue()]),
            media_type="application/pdf",
            headers={"Content-Disposition": f"attachment; filename={filename}"}
        )
    except Exception as e:
        return {"error": str(e)}
    

@router.get("/customers/complete_details/report/pdf", tags=["PDF Reports"])
@require_permission("admin")
def get_complete_customer_details_report_pdf(
    request: Request,
    customer_nic: str,
    db=Depends(get_db)
):
    """
    Generate PDF report for customer's complete details by NIC.
    Includes profile, accounts, fixed deposits, and transactions.
    
    Args:
        customer_nic: Customer's NIC number
    
    Returns:
        PDF file with complete customer details report
    """
    try:
        # Get customer by NIC
        from app.repositories.customer_repo import CustomerRepository
        from app.services.customer_service import CustomerService
        
        customer_repo = CustomerRepository(db)
        customer_service = CustomerService(customer_repo)
        
        # First get customer by NIC to get customer_id
        customer_basic = customer_repo.get_customer_by_nic(customer_nic)
        if not customer_basic:
            raise HTTPException(
                status_code=404, 
                detail=f"Customer with NIC {customer_nic} not found."
            )
        
        customer_id = customer_basic['customer_id']
        
        # Get complete customer details
        customer_data = customer_service.get_complete_customer_details(customer_id)
        
        # Generate PDF report
        pdf_service = PDFReportService(db)
        pdf_buffer = pdf_service.generate_complete_customer_details_report(customer_data)

        filename = f"customer_details_{customer_nic}.pdf"
        return StreamingResponse(
            iter([pdf_buffer.getvalue()]),
            media_type="application/pdf",
            headers={
                "Content-Disposition": f"attachment; filename={filename}",
                "Content-Type": "application/pdf"
            }
        )
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=f"Failed to generate PDF report: {str(e)}"
        )