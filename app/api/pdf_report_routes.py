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


@router.post("/pdf")
async def get_report_pdf(request: Request, db=Depends(get_db)):
    """Generate simple PDF report"""
    user = getattr(request.state, "user", None)
    user_id = user["user_id"] if user and "user_id" in user else None
    try:
        pdf_service = PDFReportService(db)
        pdf_buffer = pdf_service.generate_report(user_id=user_id)

        filename = f"report.pdf"
        return StreamingResponse(
            iter([pdf_buffer.getvalue()]),
            media_type="application/pdf",
            headers={"Content-Disposition": f"attachment; filename={filename}"}
        )
    except Exception as e:
        return {"error": str(e)}
