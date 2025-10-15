"""
Minimal PDF Report Generation
"""

from io import BytesIO
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import getSampleStyleSheet
from reportlab.lib.units import inch
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle
from reportlab.lib import colors


class PDFReportService:
    """Minimal PDF report generation"""
    
    def __init__(self):
        self.styles = getSampleStyleSheet()

    def generate_report(self, branch_name: str, total_deposits: float, total_withdrawals: float) -> BytesIO:
        """Generate simple PDF report"""
        buffer = BytesIO()
        doc = SimpleDocTemplate(buffer, pagesize=A4)
        elements = []
        
        # Title
        elements.append(Paragraph(f"Report - {branch_name}", self.styles['Heading1']))
        elements.append(Spacer(1, 0.3 * inch))
        
        # Data Table
        data = [
            ['Total Deposits', f"Rs. {total_deposits:,.2f}"],
            ['Total Withdrawals', f"Rs. {total_withdrawals:,.2f}"]
        ]
        
        table = Table(data, colWidths=[3*inch, 3*inch])
        table.setStyle(TableStyle([
            ('BACKGROUND', (0, 0), (-1, -1), colors.lightgrey),
            ('TEXTCOLOR', (0, 0), (-1, -1), colors.black),
            ('ALIGN', (0, 0), (-1, -1), 'CENTER'),
            ('FONTNAME', (0, 0), (-1, -1), 'Helvetica'),
            ('FONTSIZE', (0, 0), (-1, -1), 12),
            ('BOTTOMPADDING', (0, 0), (-1, -1), 12),
            ('GRID', (0, 0), (-1, -1), 1, colors.black)
        ]))
        elements.append(table)
        
        doc.build(elements)
        buffer.seek(0)
        return buffer
