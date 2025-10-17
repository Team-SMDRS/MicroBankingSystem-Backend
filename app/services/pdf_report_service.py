"""
Minimal PDF Report Generation
"""

from io import BytesIO
from reportlab.lib.pagesizes import A4
from decimal import Decimal
from datetime import datetime
from reportlab.lib.units import inch
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle, Image
from reportlab.lib import colors
from app.services.user_service import UserService
from app.repositories.user_repo import UserRepository
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
import os
from reportlab.lib.utils import ImageReader

class PDFReportService:
    """Minimal PDF report generation"""
    
    def __init__(self, repo):
        self.styles = getSampleStyleSheet()
        self.user_service = UserService(UserRepository(repo))
        

    def generate_users_all_transaction_report_by_id(self, user_id: str) -> BytesIO:
        """Generate simple PDF report"""
        buffer = BytesIO()
        doc = SimpleDocTemplate(
            buffer,
            pagesize=A4,
            rightMargin=1 * inch,
            leftMargin=1 * inch,
            topMargin=0.2 * inch,
            bottomMargin=1 * inch,
            # header & footer drawn on canvas in build call
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

        # Header will be drawn on every page (logo + bank name)
        logo_path = os.path.join(os.path.dirname(__file__), '..', 'static', 'images', 'logo.png')

        # Title
        user = self.user_service.get_user_by_id(user_id)
        users_name = f"{user['first_name']} {user['last_name']}"
        
        elements.append(Spacer(1, 0.8 * inch))
        centered_style = ParagraphStyle(
            name='CenteredHeading',
            parent=styles['Heading2'],
            alignment=1,  # 0=left, 1=center, 2=right
        )
        elements.append(Paragraph(f"Transaction Report Of User: {users_name}", centered_style))
        
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
            ])

            table.setStyle(TableStyle([
                ('BACKGROUND', (0, 0), (-1, 0), colors.gray),
                ('TEXTCOLOR', (0, 0), (-1, 0), colors.whitesmoke),
                ('ALIGN', (0, 0), (-1, -1), 'LEFT'),
                ('VALIGN', (0, 0), (-1, -1), 'TOP'),
                ('FONTNAME', (0, 0), (-1, 0), 'Helvetica-Bold'),
                ('FONTSIZE', (0, 0), (-1, -1), 10),
                ('BOTTOMPADDING', (0, 0), (-1, 0), 8),
                ('BACKGROUND', (0, 1), (-1, -1), colors.white),
                ('GRID', (0, 0), (-1, -1), 0.5, colors.black),
            ]))

            elements.append(table)

        # Use shared header/footer helpers from report_layout
        from app.services.report_layout import header as layout_header, footer as layout_footer

        # Build PDF: create wrappers that bind logo_path for header
        def on_first_page(canvas, doc):
            layout_header(canvas, doc, logo_path=logo_path)
            layout_footer(canvas, doc)

        def on_later_pages(canvas, doc):
            layout_header(canvas, doc, logo_path=None)  # no logo after first page
            layout_footer(canvas, doc)

        doc.build(elements, onFirstPage=on_first_page, onLaterPages=on_later_pages)
        buffer.seek(0)
        return buffer
    



    def generate_users_today_transaction_report_with_summary(self, user_id: str) -> BytesIO:
        """Generate today's transaction report for a user, including summary totals"""
        buffer = BytesIO()
        doc = SimpleDocTemplate(
            buffer,
            pagesize=A4,
            rightMargin=1 * inch,
            leftMargin=1 * inch,
            topMargin=0.2 * inch,
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
            wordWrap='CJK',
        )

        # Header and Title
        logo_path = os.path.join(os.path.dirname(__file__), '..', 'static', 'images', 'logo.png')
        user = self.user_service.get_user_by_id(user_id)
        users_name = f"{user['first_name']} {user['last_name']}"

        elements.append(Spacer(1, 0.8 * inch))
        centered_style = ParagraphStyle(
            name='CenteredHeading',
            parent=styles['Heading2'],
            alignment=1,
        )
        today=datetime.now().strftime('%Y-%m-%d')
        elements.append(Paragraph(f"Transaction Report Of User: {users_name} ({today})", centered_style))
        elements.append(Spacer(1, 0.3 * inch))

        # Get user transactions and summary
        result = self.user_service.get_today_transactions_by_user_id(user_id)
        transactions = result.get("transactions", [])
        summary = result.get("summary", {})

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
                amount = f"Rs. {float(tx['amount']):,.2f}" if isinstance(tx['amount'], (Decimal, float, int)) else str(tx['amount'])
                date = tx['created_at'].strftime('%Y-%m-%d %H:%M:%S') if isinstance(tx['created_at'], datetime) else str(tx['created_at'])

                data.append([
                    Paragraph(date, table_cell_style),
                    Paragraph(tx.get('type', ''), table_cell_style),
                    Paragraph(amount, table_cell_style),
                    Paragraph(tx.get('description', ''), table_cell_style),
                    Paragraph(str(tx.get('reference_no', '')), table_cell_style),
                ])

            # Create transaction table
            table = Table(data, colWidths=[
                1.9 * inch, 1.3 * inch, 1.3 * inch, 1.4 * inch, 1.5 * inch
            ])
            table.setStyle(TableStyle([
                ('BACKGROUND', (0, 0), (-1, 0), colors.gray),
                ('TEXTCOLOR', (0, 0), (-1, 0), colors.whitesmoke),
                ('ALIGN', (0, 0), (-1, -1), 'LEFT'),
                ('VALIGN', (0, 0), (-1, -1), 'TOP'),
                ('FONTNAME', (0, 0), (-1, 0), 'Helvetica-Bold'),
                ('FONTSIZE', (0, 0), (-1, -1), 10),
                ('BOTTOMPADDING', (0, 0), (-1, 0), 8),
                ('GRID', (0, 0), (-1, -1), 0.5, colors.black),
            ]))
            elements.append(table)
            elements.append(Spacer(1, 0.4 * inch))

            # Add summary table
            summary_data = [
                [Paragraph("<b>Summary</b>", table_cell_style), ""],
                ["Total Transactions", str(summary.get("total_transactions", 0))],
                ["Total Amount", f"Rs. {summary.get('total_amount', 0):,.2f}"],
                ["Total Deposits", f"Rs. {summary.get('total_deposit', 0):,.2f}"],
                ["Total Withdrawals", f"Rs. {summary.get('total_withdrawal', 0):,.2f}"],
                ["Bank Transfer In", f"Rs. {summary.get('total_banktransfer_in', 0):,.2f}"],
                ["Bank Transfer Out", f"Rs. {summary.get('total_banktransfer_out', 0):,.2f}"],
                ["Net Change", f"Rs. {summary.get('numeric_sum', 0):,.2f}"],
            ]

            summary_table = Table(summary_data, colWidths=[2.5 * inch, 2.5 * inch])
            summary_table.setStyle(TableStyle([
                ('GRID', (0, 0), (-1, -1), 0.5, colors.black),
                ('BACKGROUND', (0, 0), (-1, 0), colors.lightgrey),
                ('FONTNAME', (0, 0), (-1, 0), 'Helvetica-Bold'),
                ('ALIGN', (0, 0), (-1, -1), 'LEFT'),
            ]))
            elements.append(summary_table)

        # Import shared layout helpers
        from app.services.report_layout import header as layout_header, footer as layout_footer

        def on_first_page(canvas, doc):
            layout_header(canvas, doc, logo_path=logo_path)
            layout_footer(canvas, doc)

        def on_later_pages(canvas, doc):
            layout_header(canvas, doc, logo_path=None)
            layout_footer(canvas, doc)

        doc.build(elements, onFirstPage=on_first_page, onLaterPages=on_later_pages)
        buffer.seek(0)
        return buffer

        