"""
Minimal PDF Report Generation
"""

from io import BytesIO
from reportlab.lib.pagesizes import A4
from decimal import Decimal
from datetime import datetime, date
from reportlab.lib.units import inch
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle, Image
from reportlab.lib import colors
from app.services.user_service import UserService
from app.repositories.user_repo import UserRepository
from app.services.transaction_management_service import TransactionManagementService
from app.repositories.transaction_management_repo import TransactionManagementRepository
from app.services.branch_service import BranchService
from app.repositories.branch_repo import BranchRepository
from app.services.fixed_deposit_service import FixedDepositService
from app.repositories.fixed_deposit_repo import FixedDepositRepository
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
import os
from reportlab.lib.utils import ImageReader

class PDFReportService:
    """Minimal PDF report generation"""
    
    def __init__(self, repo):
        self.styles = getSampleStyleSheet()
        self.user_service = UserService(UserRepository(repo))
        self.transaction_service = TransactionManagementService(TransactionManagementRepository(repo))
        self.branch_service = BranchService(BranchRepository(repo))
        self.fixed_deposit_service = FixedDepositService(FixedDepositRepository(repo))
  

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
        print("DEBUG result:", result)  # Debugging line
        transactions = result.get("transactions", [])
        summary = result.get("summary", {})

        if not transactions:
            elements.append(Paragraph("No transactions found.", styles['Normal']))
        else:
            # Table headers
            data = [[
                Paragraph("Time", table_cell_style),
                Paragraph("Type", table_cell_style),
                Paragraph("Amount", table_cell_style),
                Paragraph("Description", table_cell_style),
                Paragraph("Reference No", table_cell_style),
            ]]

            # Table rows
            for tx in transactions:
                amount = f"Rs. {float(tx['amount']):,.2f}" if isinstance(tx['amount'], (Decimal, float, int)) else str(tx['amount'])
                # Extract only time from 'created_at'
                if isinstance(tx['created_at'], datetime):
                    date = tx['created_at'].strftime('%H:%M:%S')
                else:
                    # If it's a string like '2025-10-17T23:31:08.549325'
                    try:
                        date = tx['created_at'].split('T')[1].split('.')[0]  # '23:31:08'
                    except Exception:
                        date = str(tx['created_at'])

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

    
    def generate_date_range_transactions_report_by_branch(self, branch_id: str, start_date: str, end_date: str) -> BytesIO:
        """Generate daily transactions report for a specific branch."""
        buffer = BytesIO()

        # Convert string dates to datetime.date
        start_date_obj = datetime.strptime(start_date, '%Y-%m-%d').date() if isinstance(start_date, str) else start_date
        end_date_obj = datetime.strptime(end_date, '%Y-%m-%d').date() if isinstance(end_date, str) else end_date

        # Get branch name from service
        branch = self.branch_service.get_branch_by_id(branch_id)
        branch_name = branch[0]['name'] if branch else "Unknown Branch"
        
        # Fetch transactions and summary from service
        result = self.transaction_service.get_branch_transactions_report(
            branch_id=branch_id,
            start_date=start_date_obj,
            end_date=end_date_obj
        )

        transactions = result.get("transactions", [])
        summary = result.get("type_summary", {})

        # Create PDF document
        doc = SimpleDocTemplate(
            buffer,
            pagesize=A4,
            rightMargin=1 * inch,
            leftMargin=1 * inch,
            topMargin=0.5 * inch,
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

        # Header / Title
        centered_style = ParagraphStyle(
            name='CenteredHeading',
            parent=styles['Heading2'],
            alignment=1,
        )
        today = datetime.now().strftime('%Y-%m-%d')
        elements.append(Spacer(1, 1 * inch))
        elements.append(Paragraph(f"Transaction Report of {branch_name}  Branch: ({start_date}) to ({end_date})", centered_style))
        elements.append(Spacer(1, 0.3 * inch))

        if not transactions:
            elements.append(Paragraph("No transactions found.", normal_style))
        else:
            # Transaction Table
            data = [[
                Paragraph("Date & Time", table_cell_style),
                Paragraph("Type", table_cell_style),
                Paragraph("Amount", table_cell_style),
                Paragraph("Description", table_cell_style),
                Paragraph("Reference No", table_cell_style),
            ]]

            for tx in transactions:
                # Format amount
                amount = f"Rs. {float(tx['amount']):,.2f}" if isinstance(tx['amount'], (Decimal, float, int)) else str(tx['amount'])

                # Extract date and time from created_at
                if isinstance(tx['created_at'], datetime):
                    datetime_str = tx['created_at'].strftime('%Y-%m-%d %H:%M:%S')
                else:
                    # Handle ISO string like '2025-10-17T23:31:08.549325'
                    try:
                        # Split at 'T', then take date and time part
                        date_part, time_part = tx['created_at'].split('T')
                        time_part = time_part.split('.')[0]  # Remove microseconds if present
                        datetime_str = f"{date_part} {time_part}"
                    except Exception:
                        datetime_str = str(tx['created_at'])

                data.append([
                    Paragraph(datetime_str, table_cell_style),
                    Paragraph(tx.get('type', ''), table_cell_style),
                    Paragraph(amount, table_cell_style),
                    Paragraph(tx.get('description', ''), table_cell_style),
                    Paragraph(str(tx.get('reference_no', '')), table_cell_style),
                ])

            table = Table(data, colWidths=[1.6*inch, 1.5*inch, 1.5*inch, 1.8*inch, 1.5*inch])
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
            elements.append(Spacer(1, 0.3 * inch))

            # Summary Table
            total_deposit = sum(v['total_amount'] for k, v in summary.items() if k.lower() == 'deposit')
            total_withdrawal = sum(v['total_amount'] for k, v in summary.items() if k.lower() == 'withdrawal')
            total_in = sum(v['total_amount'] for k, v in summary.items() if k.lower() == 'banktransfer-in')
            total_out = sum(v['total_amount'] for k, v in summary.items() if k.lower() == 'banktransfer-out')
            net_change = total_deposit + total_in - total_withdrawal - total_out

            summary_data = [
                ["Summary", ""],
                ["Total Transactions", str(result.get("total_transactions", 0))],
                ["Total Amount", f"Rs. {result.get('total_amount', 0):,.2f}"],
                ["Total Deposits", f"Rs. {total_deposit:,.2f}"],
                ["Total Withdrawals", f"Rs. {total_withdrawal:,.2f}"],
                ["Bank Transfer In", f"Rs. {total_in:,.2f}"],
                ["Bank Transfer Out", f"Rs. {total_out:,.2f}"],
                ["Net Change", f"Rs. {net_change:,.2f}"],
            ]

            summary_table = Table(summary_data, colWidths=[2*inch, 2*inch])
            summary_table.setStyle(TableStyle([
                ('GRID', (0, 0), (-1, -1), 0.5, colors.black),
                ('BACKGROUND', (0, 0), (-1, 0), colors.lightgrey),
                ('FONTNAME', (0, 0), (-1, 0), 'Helvetica-Bold'),
                ('ALIGN', (0, 0), (-1, -1), 'LEFT'),
            ]))
            elements.append(summary_table)

        # Add header/footer if you have layout helpers
        from app.services.report_layout import header as layout_header, footer as layout_footer

        def on_first_page(canvas, doc):
            logo_path = os.path.join(os.path.dirname(__file__), '..', 'static', 'images', 'logo.png')
            layout_header(canvas, doc, logo_path=logo_path)
            layout_footer(canvas, doc)

        def on_later_pages(canvas, doc):
            layout_header(canvas, doc, logo_path=None)
            layout_footer(canvas, doc)

        doc.build(elements, onFirstPage=on_first_page, onLaterPages=on_later_pages)
        buffer.seek(0)
        return buffer

    def generate_date_range_transactions_report_by_customer(self, customer_id: str, start_date: str, end_date: str) -> BytesIO:
        """Generate transactions report for a specific customer within a date range."""
        buffer = BytesIO()

        # Convert string dates to datetime.date
        start_date_obj = datetime.strptime(start_date, '%Y-%m-%d').date() if isinstance(start_date, str) else start_date
        end_date_obj = datetime.strptime(end_date, '%Y-%m-%d').date() if isinstance(end_date, str) else end_date

        # Get customer details
        from app.repositories.customer_repo import CustomerRepository
        from app.services.customer_service import CustomerService
        
        customer_repo = CustomerRepository(self.transaction_service.transaction_repo.conn)
        customer_service = CustomerService(customer_repo)
        
        customer = customer_repo.get_customer_by_id(customer_id)
        customer_name = customer['full_name'] if customer else "Unknown Customer"
        
        # Fetch customer transactions within date range
        transactions = customer_repo.get_customer_transactions(customer_id)
        
        # Filter transactions by date range
        filtered_transactions = []
        for tx in transactions:
            tx_date = tx['created_at'].date() if isinstance(tx['created_at'], datetime) else datetime.strptime(str(tx['created_at']).split('T')[0], '%Y-%m-%d').date()
            if start_date_obj <= tx_date <= end_date_obj:
                filtered_transactions.append(tx)
        
        # Sort transactions by date (most recent first)
        filtered_transactions.sort(key=lambda x: x['created_at'], reverse=True)
        
        # Calculate summary statistics
        total_deposit = sum(float(tx['amount']) for tx in filtered_transactions if tx['type'].lower() == 'deposit')
        total_withdrawal = sum(float(tx['amount']) for tx in filtered_transactions if tx['type'].lower() == 'withdrawal')
        total_transfer_in = sum(float(tx['amount']) for tx in filtered_transactions if tx['type'].lower() == 'banktransfer-in')
        total_transfer_out = sum(float(tx['amount']) for tx in filtered_transactions if tx['type'].lower() == 'banktransfer-out')
        net_change = total_deposit + total_transfer_in - total_withdrawal - total_transfer_out

        # Create PDF document
        doc = SimpleDocTemplate(
            buffer,
            pagesize=A4,
            rightMargin=1 * inch,
            leftMargin=1 * inch,
            topMargin=0.5 * inch,
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

        # Header / Title
        centered_style = ParagraphStyle(
            name='CenteredHeading',
            parent=styles['Heading2'],
            alignment=1,
        )
        elements.append(Spacer(1, 1 * inch))
        elements.append(Paragraph(f"Transaction Report for {customer_name}", centered_style))
        elements.append(Spacer(1, 0.1 * inch))
        
        # Add date range subtitle
        subtitle_style = ParagraphStyle(
            name='Subtitle',
            parent=styles['Normal'],
            alignment=1,
            fontSize=11,
        )
        elements.append(Paragraph(f"Period: {start_date} to {end_date}", subtitle_style))
        elements.append(Spacer(1, 0.3 * inch))

        if not filtered_transactions:
            elements.append(Paragraph("No transactions found for the specified date range.", normal_style))
        else:
            # Transaction Table
            data = [[
                Paragraph("Date & Time", table_cell_style),
                Paragraph("Account", table_cell_style),
                Paragraph("Type", table_cell_style),
                Paragraph("Amount", table_cell_style),
                Paragraph("Description", table_cell_style),
            ]]

            for tx in filtered_transactions:
                # Format amount
                amount = f"Rs. {float(tx['amount']):,.2f}" if isinstance(tx['amount'], (Decimal, float, int)) else str(tx['amount'])

                # Extract date and time from created_at
                if isinstance(tx['created_at'], datetime):
                    datetime_str = tx['created_at'].strftime('%Y-%m-%d %H:%M')
                else:
                    # Handle ISO string like '2025-10-17T23:31:08.549325'
                    try:
                        date_part, time_part = tx['created_at'].split('T')
                        time_part = time_part.split('.')[0]  # Remove microseconds
                        time_short = ':'.join(time_part.split(':')[:2])  # HH:MM only
                        datetime_str = f"{date_part} {time_short}"
                    except Exception:
                        datetime_str = str(tx['created_at'])

                data.append([
                    Paragraph(datetime_str, table_cell_style),
                    Paragraph(str(tx.get('account_no', '')), table_cell_style),
                    Paragraph(tx.get('type', ''), table_cell_style),
                    Paragraph(amount, table_cell_style),
                    Paragraph(tx.get('description', '')[:50], table_cell_style),  # Truncate long descriptions
                ])

            table = Table(data, colWidths=[1.5*inch, 1.5*inch, 1.3*inch, 1.3*inch, 2.3*inch])
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
            elements.append(Spacer(1, 0.3 * inch))

            # Summary Table
            summary_data = [
                [Paragraph("<b>Transaction Summary</b>", table_cell_style), ""],
                ["Total Transactions", str(len(filtered_transactions))],
                ["Total Deposits", f"Rs. {total_deposit:,.2f}"],
                ["Total Withdrawals", f"Rs. {total_withdrawal:,.2f}"],
                ["Bank Transfer In", f"Rs. {total_transfer_in:,.2f}"],
                ["Bank Transfer Out", f"Rs. {total_transfer_out:,.2f}"],
                ["Net Change", f"Rs. {net_change:,.2f}"],
            ]

            summary_table = Table(summary_data, colWidths=[2.5*inch, 2.5*inch])
            summary_table.setStyle(TableStyle([
                ('GRID', (0, 0), (-1, -1), 0.5, colors.black),
                ('BACKGROUND', (0, 0), (-1, 0), colors.lightgrey),
                ('FONTNAME', (0, 0), (-1, 0), 'Helvetica-Bold'),
                ('ALIGN', (0, 0), (-1, -1), 'LEFT'),
                ('VALIGN', (0, 0), (-1, -1), 'TOP'),
            ]))
            elements.append(summary_table)

        # Add header/footer
        from app.services.report_layout import header as layout_header, footer as layout_footer

        def on_first_page(canvas, doc):
            logo_path = os.path.join(os.path.dirname(__file__), '..', 'static', 'images', 'logo.png')
            layout_header(canvas, doc, logo_path=logo_path)
            layout_footer(canvas, doc)

        def on_later_pages(canvas, doc):
            layout_header(canvas, doc, logo_path=None)
            layout_footer(canvas, doc)

        doc.build(elements, onFirstPage=on_first_page, onLaterPages=on_later_pages)
        buffer.seek(0)
        return buffer




    def generate_date_range_transactions_report_by_account(self, account_number: int, start_date: str, end_date: str) -> BytesIO:
        """Generate transactions report for a specific account within a date range."""
        buffer = BytesIO()
        
        # Convert string dates to datetime.date
        start_date_obj = datetime.strptime(start_date, '%Y-%m-%d').date() if isinstance(start_date, str) else start_date
        end_date_obj = datetime.strptime(end_date, '%Y-%m-%d').date() if isinstance(end_date, str) else end_date
        
        # Get account ID from account number
        acc_id = self.transaction_service.transaction_repo.get_account_id_by_account_no(account_number)
        if not acc_id:
            raise ValueError(f"Account with number {account_number} not found")
        
        # Get transaction summary with history using the service
        account_detail = self.transaction_service.get_transaction_with_summary(
            acc_id=acc_id,
            start_date=start_date_obj,
            end_date=end_date_obj
        )
        
        # Extract data
        account_no = account_detail['account_no']
        current_balance = account_detail['current_balance']
        summary = account_detail['summary']
        transactions = account_detail['transactions']
        
        # Create PDF document
        doc = SimpleDocTemplate(
            buffer,
            pagesize=A4,
            rightMargin=1 * inch,
            leftMargin=1 * inch,
            topMargin=0.5 * inch,
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
        
        # Header / Title
        centered_style = ParagraphStyle(
            name='CenteredHeading',
            parent=styles['Heading2'],
            alignment=1,
        )
        elements.append(Spacer(1, 1 * inch))
        elements.append(Paragraph(f"Transaction Report for Account {account_no}", centered_style))
        elements.append(Spacer(1, 0.1 * inch))
        
        # Add date range subtitle
        subtitle_style = ParagraphStyle(
            name='Subtitle',
            parent=styles['Normal'],
            alignment=1,
            fontSize=11,
        )
        elements.append(Paragraph(f"Period: {start_date} to {end_date}", subtitle_style))
        elements.append(Spacer(1, 0.3 * inch))
        
        if not transactions:
            elements.append(Paragraph("No transactions found for the specified date range.", normal_style))
        else:
            # Transaction Table
            data = [[
                Paragraph("Date & Time", table_cell_style),
                Paragraph("Type", table_cell_style),
                Paragraph("Amount", table_cell_style),
                Paragraph("Description", table_cell_style),
                Paragraph("Reference No", table_cell_style),
            ]]
            
            for tx in transactions:
                # Format amount
                amount = f"Rs. {float(tx['amount']):,.2f}" if isinstance(tx['amount'], (Decimal, float, int)) else str(tx['amount'])
                
                # Extract date and time from created_at
                if isinstance(tx['created_at'], datetime):
                    datetime_str = tx['created_at'].strftime('%Y-%m-%d %H:%M')
                else:
                    # Handle ISO string like '2025-10-17T23:31:08.549325'
                    try:
                        date_part, time_part = tx['created_at'].split('T')
                        time_part = time_part.split('.')[0]  # Remove microseconds
                        time_short = ':'.join(time_part.split(':')[:2])  # HH:MM only
                        datetime_str = f"{date_part} {time_short}"
                    except Exception:
                        datetime_str = str(tx['created_at'])
                
                data.append([
                    Paragraph(datetime_str, table_cell_style),
                    Paragraph(tx.get('type', ''), table_cell_style),
                    Paragraph(amount, table_cell_style),
                    Paragraph(tx.get('description', '')[:50], table_cell_style),  # Truncate long descriptions
                    Paragraph(str(tx.get('reference_no', '')), table_cell_style),
                ])
            
            table = Table(data, colWidths=[1.5*inch, 1.3*inch, 1.3*inch, 1.4*inch, 1.5*inch])
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
            elements.append(Spacer(1, 0.3 * inch))
            
            # Summary Table
            total_deposits = summary.get('total_deposit_amount', 0)
            total_withdrawals = summary.get('total_withdrawal_amount', 0)
            total_transfer_in = summary.get('total_transfer_in', 0)
            total_transfer_out = summary.get('total_transfer_out', 0)
            net_change = total_deposits + total_transfer_in - total_withdrawals - total_transfer_out
            
            summary_data = [
                [Paragraph("<b>Transaction Summary</b>", table_cell_style), ""],
                ["Total Transactions", str(summary.get('total_transactions', 0))],
                ["Current Balance", f"Rs. {current_balance:,.2f}"],
                ["Total Deposits", f"Rs. {total_deposits:,.2f}"],
                ["Total Withdrawals", f"Rs. {total_withdrawals:,.2f}"],
                ["Bank Transfer In", f"Rs. {total_transfer_in:,.2f}"],
                ["Bank Transfer Out", f"Rs. {total_transfer_out:,.2f}"],
                ["Average Transaction", f"Rs. {summary.get('avg_transaction_amount', 0):,.2f}"],
                ["Max Transaction", f"Rs. {summary.get('max_transaction_amount', 0):,.2f}"],
                ["Min Transaction", f"Rs. {summary.get('min_transaction_amount', 0):,.2f}"],
                ["Net Change", f"Rs. {net_change:,.2f}"],
            ]
            
            summary_table = Table(summary_data, colWidths=[2.5*inch, 2.5*inch])
            summary_table.setStyle(TableStyle([
                ('GRID', (0, 0), (-1, -1), 0.5, colors.black),
                ('BACKGROUND', (0, 0), (-1, 0), colors.lightgrey),
                ('FONTNAME', (0, 0), (-1, 0), 'Helvetica-Bold'),
                ('ALIGN', (0, 0), (-1, -1), 'LEFT'),
                ('VALIGN', (0, 0), (-1, -1), 'TOP'),
            ]))
            elements.append(summary_table)
        
        # Add header/footer
        from app.services.report_layout import header as layout_header, footer as layout_footer
        
        def on_first_page(canvas, doc):
            logo_path = os.path.join(os.path.dirname(__file__), '..', 'static', 'images', 'logo.png')
            layout_header(canvas, doc, logo_path=logo_path)
            layout_footer(canvas, doc)
        
        def on_later_pages(canvas, doc):
            layout_header(canvas, doc, logo_path=None)
            layout_footer(canvas, doc)
        
        doc.build(elements, onFirstPage=on_first_page, onLaterPages=on_later_pages)
        buffer.seek(0)
        return buffer



    def generate_active_fd_with_next_interest_payment_date_report(self) -> BytesIO:
        """Generate report of active fixed deposits with next interest payment date."""
        buffer = BytesIO()
        doc = SimpleDocTemplate(
            buffer,
            pagesize=A4,
            rightMargin=1 * inch,
            leftMargin=1 * inch,
            topMargin=0.5 * inch,
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
        
        elements.append(Spacer(1, 0.8 * inch))
        centered_style = ParagraphStyle(
            name='CenteredHeading',
            parent=styles['Heading2'],
            alignment=1,
        )
        elements.append(Paragraph(f"Active Fixed Deposits with Next Interest Payment Date", centered_style))
        elements.append(Spacer(1, 0.3 * inch))

        # Get active FD data
        fds = self.fixed_deposit_service.get_fd_accounts_with_next_interest_payment_date()
        
        if not fds:
            elements.append(Paragraph("No active fixed deposits found.", styles['Normal']))
        else:
            # Table headers
            data = [[
                Paragraph("Account No", table_cell_style),
                Paragraph("Next Interest Payment Date", table_cell_style),
                Paragraph("Maturity Date", table_cell_style),
            ]]

            # Table rows
            for fd in fds:
                account_no = str(fd['fd_account_no']) if 'fd_account_no' in fd else str(fd.get('account_no', ''))
                next_interest_date = fd['next_interest_day'].strftime('%Y-%m-%d') if isinstance(fd['next_interest_day'], (datetime, date)) else str(fd['next_interest_day'])
                maturity_date = fd['maturity_date'].strftime('%Y-%m-%d') if isinstance(fd['maturity_date'], datetime) else str(fd['maturity_date'])

                data.append([
                    Paragraph(account_no, table_cell_style),
                    Paragraph(next_interest_date, table_cell_style),
                    Paragraph(maturity_date, table_cell_style),
                ])

            # Create table with adjusted column widths
            table = Table(data, colWidths=[
                2.5 * inch,  # Account No
                2.5 * inch,  # Next Interest Payment Date
                2.5 * inch,  # Maturity Date
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

        # Add header/footer using shared layout helpers
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
        