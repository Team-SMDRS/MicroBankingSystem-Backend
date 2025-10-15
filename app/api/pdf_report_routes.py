"""
Simple Transaction Report API
"""

from fastapi import APIRouter
from pydantic import BaseModel
from app.services.pdf_report_service import PDFReportService
from fastapi.responses import StreamingResponse

router = APIRouter(prefix="/api/transaction-report", tags=["Reports"])


class SimplePDFRequest(BaseModel):
    """Minimal PDF request"""
    branch_name: str
    total_deposits: float
    total_withdrawals: float


@router.post("/pdf")
async def get_report_pdf(request: SimplePDFRequest):
    """Generate simple PDF report"""
    try:
        pdf_service = PDFReportService()
        pdf_buffer = pdf_service.generate_report(
            branch_name=request.branch_name,
            total_deposits=request.total_deposits,
            total_withdrawals=request.total_withdrawals
        )
        
        filename = f"report_{request.branch_name}.pdf"
        return StreamingResponse(
            iter([pdf_buffer.getvalue()]),
            media_type="application/pdf",
            headers={"Content-Disposition": f"attachment; filename={filename}"}
        )
    except Exception as e:
        return {"error": str(e)}
