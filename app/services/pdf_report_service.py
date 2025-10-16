"""
Minimal PDF Report Generation
"""

from io import BytesIO
from reportlab.lib.pagesizes import A4
from decimal import Decimal
from datetime import datetime
from reportlab.lib.units import inch
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle
from reportlab.lib import colors
from app.services.user_service import UserService
from app.repositories.user_repo import UserRepository
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
class PDFReportService:
    """Minimal PDF report generation"""
    
    def __init__(self,repo):
        self.styles = getSampleStyleSheet()
        self.user_service = UserService(UserRepository(repo))
        

    def generate_report(self, user_id: str) -> BytesIO:
        """Generate simple PDF report"""
        buffer = BytesIO()
        doc = SimpleDocTemplate(
        buffer,
        pagesize=A4,
        rightMargin=1 * inch,
        leftMargin=1 * inch,
        topMargin=1 * inch,
        bottomMargin=1 * inch,
    )
        elements = []

        styles = getSampleStyleSheet()
        normal_style = styles['Normal']
        table_cell_style = ParagraphStyle(
            name='TableCell',
            parent=normal_style,
            fontSize=10,
            leading=12,
            wordWrap='CJK',  # allows breaking long words
        )

        # Title
        elements.append(Paragraph(f"Transaction Report for User: {user_id}", styles['Heading1']))
        elements.append(Spacer(1, 0.3 * inch))

        # Get user transaction data
        transactions = self.user_service.get_transactions_by_user_id(user_id)

        if not transactions:
            elements.append(Paragraph("No transactions found.", styles['Normal']))
        else:
            # Table headers
            data = [[
                Paragraph("Date", table_cell_style),
                Paragraph("Type", table_cell_style),
                Paragraph("Amount", table_cell_style),
                Paragraph("Description", table_cell_style),
                Paragraph("Reference No", table_cell_style),
            ]]

            # Table rows
            for tx in transactions:
                amount = f"Rs. {float(tx['amount']):,.2f}" if isinstance(tx['amount'], Decimal) else str(tx['amount'])
                date = tx['created_at'].strftime('%Y-%m-%d %H:%M:%S') if isinstance(tx['created_at'], datetime) else str(tx['created_at'])

                data.append([
                    Paragraph(date, table_cell_style),
                    Paragraph(tx.get('type', ''), table_cell_style),
                    Paragraph(amount, table_cell_style),
                    Paragraph(tx.get('description', ''), table_cell_style),
                    Paragraph(str(tx.get('reference_no', '')), table_cell_style),
                ])

            # Create table with adjusted column widths
            table = Table(data, colWidths=[
    1.9 * inch,  # Date
    1.3 * inch,  # Type
    1.3 * inch,  # Amount
    1.4 * inch,  # Description
    1.5 * inch,  # Reference No
]
)

            table.setStyle(TableStyle([
                ('BACKGROUND', (0, 0), (-1, 0), colors.grey),
                ('TEXTCOLOR', (0, 0), (-1, 0), colors.whitesmoke),
                ('ALIGN', (0, 0), (-1, -1), 'LEFT'),
                ('VALIGN', (0, 0), (-1, -1), 'TOP'),
                ('FONTNAME', (0, 0), (-1, 0), 'Helvetica-Bold'),
                ('FONTSIZE', (0, 0), (-1, -1), 10),
                ('BOTTOMPADDING', (0, 0), (-1, 0), 8),
                ('BACKGROUND', (0, 1), (-1, -1), colors.beige),
                ('GRID', (0, 0), (-1, -1), 0.5, colors.black),
            ]))

            elements.append(table)

        # Build PDF
        doc.build(elements)
        buffer.seek(0)
        return buffer