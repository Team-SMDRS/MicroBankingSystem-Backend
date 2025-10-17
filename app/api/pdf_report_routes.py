"""
Simple Transaction Report API
"""


from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel
from app.services.pdf_report_service import PDFReportService
from fastapi.responses import StreamingResponse
from app.database.db import get_db
router = APIRouter()


class SimplePDFRequest(BaseModel):
    """Minimal PDF request"""
    branch_name: str
    total_deposits: float
    total_withdrawals: float


@router.get("/users/report/pdf", tags=["PDF Reports"])
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
async def get_admin_users_all_transaction_report_pdf(user_id: str, db=Depends(get_db)):
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