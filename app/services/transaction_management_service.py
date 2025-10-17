from app.repositories.transaction_management_repo import TransactionManagementRepository
from app.schemas.transaction_management_schema import (
    DepositRequest, WithdrawRequest, TransferRequest, TransactionResponse, TransactionStatusResponse,
    AccountTransactionHistory, DateRangeRequest, DateRangeTransactionResponse,
    BranchReportRequest, BranchTransactionSummary, TransactionSummaryRequest,
    AccountTransactionSummary, DailyTransactionSummary, MonthlyTransactionSummary,
    TransactionAnalytics, TransactionType
)
from fastapi import HTTPException
from typing import List, Optional, Dict, Any
from datetime import datetime, date
import math

class TransactionManagementService:
    # Class-level constants
    MAX_TRANSFER_AMOUNT = 10000000.00  # Rs. 100 Lakhs daily limit
    
    def __init__(self, transaction_repo: TransactionManagementRepository):
        self.transaction_repo = transaction_repo

    def process_deposit(self, request: DepositRequest, user_id: str) -> TransactionStatusResponse:
        """Process a deposit transaction"""
        try:
            # Get acc_id from account_no
            acc_id = self.transaction_repo.get_account_id_by_account_no(request.account_no)
            if not acc_id:
                raise HTTPException(status_code=404, detail=f"Account with number {request.account_no} not found")

            # Get account with savings plan details
            account_details = self.transaction_repo.get_account_with_savings_plan(acc_id)
            if not account_details:
                raise HTTPException(status_code=404, detail="Account details not found")

            # Check if it's a Children account - no deposits allowed (except through guardian)
            plan_name = account_details.get('plan_name', '').strip()
            if plan_name == 'Children':
                raise HTTPException(
                    status_code=403, 
                    detail="Direct deposits are not allowed for Children accounts. Please contact a guardian or bank representative."
                )

            # Process deposit using repository (reference_no and transaction_id are auto-generated)
            result = self.transaction_repo.process_deposit_transaction(
                acc_id=acc_id,
                amount=request.amount,
                description=request.description,
                created_by=user_id
            )

            if result.get('success', False):
                return TransactionStatusResponse(
                    success=True,
                    message=f"Deposit of Rs.{request.amount:.2f} processed successfully",
                    transaction_id=result.get('transaction_id'),
                    reference_no=result.get('reference_no')
                )
            else:
                raise HTTPException(
                    status_code=400, 
                    detail=result.get('error_message', 'Failed to process deposit')
                )

        except HTTPException:
            raise
        except Exception as e:
            raise HTTPException(status_code=500, detail=f"Deposit processing failed: {str(e)}")

    def process_withdrawal(self, request: WithdrawRequest, user_id: str) -> TransactionStatusResponse:
        """Process a withdrawal transaction"""
        try:
            # Get acc_id from account_no
            acc_id = self.transaction_repo.get_account_id_by_account_no(request.account_no)
            if not acc_id:
                raise HTTPException(status_code=404, detail=f"Account with number {request.account_no} not found")

            # Get account with savings plan details
            account_details = self.transaction_repo.get_account_with_savings_plan(acc_id)
            if not account_details:
                raise HTTPException(status_code=404, detail="Account details not found")

            # Check if it's a Children account - no transactions allowed
            plan_name = account_details.get('plan_name', '').strip()
            if plan_name == 'Children':
                raise HTTPException(
                    status_code=403, 
                    detail="Withdrawals are not allowed for Children accounts"
                )

            # Check current account balance
            current_balance = self.transaction_repo.get_account_balance(acc_id)
            if current_balance < request.amount:
                raise HTTPException(
                    status_code=400, 
                    detail=f"Insufficient balance. Current balance: Rs.{current_balance:.2f}, Withdrawal amount: Rs.{request.amount:.2f}"
                )

            # Check minimum balance requirement
            minimum_balance = float(account_details.get('minimum_balance', 0))
            balance_after_withdrawal = current_balance - request.amount
            
            if balance_after_withdrawal < minimum_balance:
                raise HTTPException(
                    status_code=400, 
                    detail=f"Withdrawal would violate minimum balance requirement. Minimum balance: Rs.{minimum_balance:.2f}, Balance after withdrawal: Rs.{balance_after_withdrawal:.2f}"
                )

            # Process withdrawal using repository (balance check, reference_no and transaction_id are handled by database)
            result = self.transaction_repo.process_withdrawal_transaction(
                acc_id=acc_id,
                amount=request.amount,
                description=request.description,
                created_by=user_id
            )

            if result.get('success', False):
                return TransactionStatusResponse(
                    success=True,
                    message=f"Withdrawal of Rs.{request.amount:.2f} processed successfully",
                    transaction_id=result.get('transaction_id'),
                    reference_no=result.get('reference_no')
                )
            else:
                raise HTTPException(
                    status_code=400, 
                    detail=result.get('error_message', 'Failed to process withdrawal')
                )

        except HTTPException:
            raise
        except Exception as e:
            raise HTTPException(status_code=500, detail=f"Withdrawal processing failed: {str(e)}")

    def process_transfer(self, request: TransferRequest, user_id: str) -> TransactionStatusResponse:
        """
        Process a money transfer between two accounts with comprehensive business logic
        
        Business Rules:
        1. Validate both accounts exist
        2. Check sufficient funds in source account
        3. Prevent transfer to same account
        4. Ensure minimum transfer amount
        5. Handle account limits and restrictions
        6. Log transaction for audit trail
        7. Enforce minimum balance requirements
        8. Block Children account transactions
        """
        try:
            # Business Logic 1: Validate transfer amount
            if request.amount <= 0:
                raise HTTPException(status_code=400, detail="Transfer amount must be greater than 0")
            
            # Business Logic 2: Prevent same account transfer (additional validation)
            if request.from_account_no == request.to_account_no:
                raise HTTPException(status_code=400, detail="Cannot transfer money to the same account")
            
            # Business Logic 3: Get and validate source account
            from_acc_id = self.transaction_repo.get_account_id_by_account_no(request.from_account_no)
            if not from_acc_id:
                raise HTTPException(
                    status_code=404, 
                    detail=f"Source account {request.from_account_no} not found"
                )
            
            # Business Logic 4: Get and validate destination account
            to_acc_id = self.transaction_repo.get_account_id_by_account_no(request.to_account_no)
            if not to_acc_id:
                raise HTTPException(
                    status_code=404, 
                    detail=f"Destination account {request.to_account_no} not found"
                )
            
            # Business Logic 5: Get source account with savings plan details
            from_account_details = self.transaction_repo.get_account_with_savings_plan(from_acc_id)
            if not from_account_details:
                raise HTTPException(status_code=404, detail="Source account details not found")

            # Business Logic 6: Check if source account is a Children account - no transfers allowed
            from_plan_name = from_account_details.get('plan_name', '').strip()
            if from_plan_name == 'Children':
                raise HTTPException(
                    status_code=403, 
                    detail="Transfers are not allowed from Children accounts"
                )

            # Business Logic 7: Check if destination account is a Children account - no transfers allowed
            to_account_details = self.transaction_repo.get_account_with_savings_plan(to_acc_id)
            if to_account_details:
                to_plan_name = to_account_details.get('plan_name', '').strip()
                if to_plan_name == 'Children':
                    raise HTTPException(
                        status_code=403, 
                        detail="Transfers are not allowed to Children accounts"
                    )
            
            # Business Logic 8: Check current balance for sufficient funds
            current_balance = self.transaction_repo.get_account_balance(from_acc_id)
            if current_balance < request.amount:
                raise HTTPException(
                    status_code=400,
                    detail=f"Insufficient balance. Current balance: Rs.{current_balance:.2f}, Transfer amount: Rs.{request.amount:.2f}"
                )
            
            # Business Logic 9: Check minimum balance requirement for source account
            minimum_balance = float(from_account_details.get('minimum_balance', 0))
            balance_after_transfer = current_balance - request.amount
            
            if balance_after_transfer < minimum_balance:
                raise HTTPException(
                    status_code=400, 
                    detail=f"Transfer would violate minimum balance requirement. Minimum balance: Rs.{minimum_balance:.2f}, Balance after transfer: Rs.{balance_after_transfer:.2f}"
                )
            
            # Business Logic 10: Apply transfer limits (example business rule)
            if request.amount > self.MAX_TRANSFER_AMOUNT:
                raise HTTPException(
                    status_code=400,
                    detail=f"Transfer amount exceeds maximum limit of Rs.{self.MAX_TRANSFER_AMOUNT:.2f}"
                )
            
            # Business Logic 11: Check daily transfer limit (optional enhancement)
            # daily_transferred = self.transaction_repo.get_daily_transfer_amount(from_acc_id)
            # if daily_transferred + request.amount > MAX_TRANSFER_AMOUNT:
            #     raise HTTPException(
            #         status_code=400,
            #         detail=f"Daily transfer limit exceeded. Already transferred: Rs.{daily_transferred:.2f}"
            #     )
            
            # Business Logic 12: Process the transfer using repository
            result = self.transaction_repo.process_transfer_transaction(
                from_acc_id=from_acc_id,
                to_acc_id=to_acc_id,
                amount=request.amount,
                description=request.description or f"Transfer from {request.from_account_no} to {request.to_account_no}",
                created_by=user_id
            )
            
            # Business Logic 13: Handle transfer result
            if result.get('success', False):
                return TransactionStatusResponse(
                    success=True,
                    message=f"Transfer of Rs.{request.amount:.2f} from account {request.from_account_no} to {request.to_account_no} processed successfully",
                    transaction_id=result.get('transaction_id'),
                    reference_no=result.get('reference_no'),
                    additional_info={
                        "from_account_balance": result.get('from_balance'),
                        "to_account_balance": result.get('to_balance'),
                        "transfer_amount": request.amount,
                        "from_account_no": request.from_account_no,
                        "to_account_no": request.to_account_no
                    }
                )
            else:
                error_msg = result.get('error_message', 'Failed to process transfer')
                raise HTTPException(status_code=400, detail=error_msg)
                
        except HTTPException:
            raise
        except Exception as e:
            raise HTTPException(status_code=500, detail=f"Transfer processing failed: {str(e)}")

    def get_account_transactions(self, acc_id: str, page: int = 1, per_page: int = 50) -> AccountTransactionHistory:
        """Get transaction history for a specific account"""
        try:
            # Validate account exists
            if not self.transaction_repo.account_exists(acc_id):
                raise HTTPException(status_code=404, detail="Account not found")

            # Validate pagination parameters
            if page < 1 or per_page < 1:
                raise HTTPException(status_code=400, detail="Page and per_page must be greater than 0")

            if per_page > 100:
                per_page = 100  # Limit maximum per page

            # Calculate offset
            offset = (page - 1) * per_page

            # Get transactions and total count with balance_after
            transactions_data, total_count = self.transaction_repo.get_transaction_history_by_account_with_balance(
                acc_id, per_page, offset
            )

            # Get current balance
            current_balance = self.transaction_repo.get_account_balance(acc_id)

            # Convert to response models
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
        balance_after=float(tx.get('balance_after', 0)) if tx.get('balance_after') else None
    )
    for tx in transactions_data
]

            # Calculate total pages
            total_pages = math.ceil(total_count / per_page) if total_count > 0 else 1

            return AccountTransactionHistory(
                acc_id=acc_id,
                transactions=transactions,
                total_count=total_count,
                page=page,
                per_page=per_page,
                total_pages=total_pages,
                current_balance=current_balance
            )

        except HTTPException:
            raise
        except Exception as e:
            raise HTTPException(status_code=500, detail=f"Failed to get account transactions: {str(e)}")

    def get_account_transactions_by_account_no(self, account_no: int, page: int = 1, per_page: int = 50) -> AccountTransactionHistory:
        """Get transaction history for a specific account using account number"""
        try:
            # Get acc_id from account_no
            acc_id = self.transaction_repo.get_account_id_by_account_no(account_no)
            if not acc_id:
                raise HTTPException(status_code=404, detail=f"Account with number {account_no} not found")

            # Use existing method with acc_id
            return self.get_account_transactions(acc_id, page, per_page)

        except HTTPException:
            raise
        except Exception as e:
            raise HTTPException(status_code=500, detail=f"Failed to get account transactions: {str(e)}")

    def get_transactions_by_date_range(self, request: DateRangeRequest) -> DateRangeTransactionResponse:
        """Get transactions within a date range"""
        try:
            # If account specified, validate it exists
           

            # Get transactions with balance_after
            transactions_data = self.transaction_repo.get_transaction_history_by_date_range_with_balance(
                start_date=request.start_date,
                end_date=request.end_date,
              
                transaction_type=request.transaction_type.value if request.transaction_type else None
            )

            # Convert to response models
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
                    balance_after=float(tx['balance_after']) if tx.get('balance_after') is not None else None,
                    username=tx['username'] if tx.get('username') is not None else None,
                    account_no=tx['account_no'] if tx.get('account_no') is not None else None
                )
                for tx in transactions_data
            ]

            # Calculate summary
            total_deposits = sum(tx.amount for tx in transactions if tx.type == TransactionType.DEPOSIT)
            total_withdrawals = sum(tx.amount for tx in transactions if tx.type == TransactionType.WITHDRAWAL)
            total_transfers = sum(tx.amount for tx in transactions if tx.type == TransactionType.BANK_TRANSFER_IN or tx.type == TransactionType.BANK_TRANSFER_OUT)

            summary = {
                'total_transactions': len(transactions),
                'total_deposits': total_deposits,
                'total_withdrawals': total_withdrawals,
                'total_transfers': total_transfers,
                'net_change': total_deposits - total_withdrawals,
                'average_transaction': sum(tx.amount for tx in transactions) / len(transactions) if transactions else 0
            }

            return DateRangeTransactionResponse(
                transactions=transactions,
                total_count=len(transactions),
                date_range={
                    'start_date': request.start_date.isoformat(),
                    'end_date': request.end_date.isoformat()
                },
                summary=summary
            )

        except HTTPException:
            raise
        except Exception as e:
            raise HTTPException(status_code=500, detail=f"Failed to get transactions by date range: {str(e)}")

    def get_branch_transaction_report(self, request: BranchReportRequest) -> BranchTransactionSummary:
        """Get transaction report for a specific branch"""
        try:
            # Get branch report data
            report_data = self.transaction_repo.get_branch_transaction_report(
                branch_id=request.branch_id,
                start_date=request.start_date,
                end_date=request.end_date,
                transaction_type=request.transaction_type.value if request.transaction_type else None
            )

            if not report_data:
                raise HTTPException(status_code=404, detail="Branch not found or no data available")

            # Get top accounts for this branch
            top_accounts = self.transaction_repo.get_top_accounts_by_volume(
                branch_id=request.branch_id,
               
                start_date=request.start_date,
                end_date=request.end_date
            )

            all_accounts_list = [
                {
                    'acc_id': acc['acc_id'],
                    'acc_holder_name': acc.get('full_name') or acc.get('account_holder_name'),
                    'transaction_count': acc['transaction_count'],
                    'total_volume': float(acc['total_volume'])
                }
                for acc in top_accounts
            ]

            # Calculate total transfers and net amount
            total_transfers_in = report_data.get('total_transfers_in', 0)
            total_transfers_out = report_data.get('total_transfers_out', 0)
            total_deposits = report_data.get('total_deposits', 0)
            total_withdrawals = report_data.get('total_withdrawals', 0)
            
            # Total transfers is the sum of both in and out
            total_transfers = total_transfers_in + total_transfers_out
            
            # Net amount: incoming - outgoing
            net_amount = total_deposits + total_transfers_in - total_withdrawals - total_transfers_out

            return BranchTransactionSummary(
                branch_id=request.branch_id,
                branch_name=report_data.get('branch_name'),
                total_deposits=total_deposits,
                total_withdrawals=total_withdrawals,
                total_transfers_in=total_transfers_in,
                total_transfers_out=total_transfers_out,
                total_transfers=total_transfers,
                net_amount=net_amount,
                transaction_count=report_data.get('transaction_count', 0),
                date_range={
                    'start_date': request.start_date.isoformat(),
                    'end_date': request.end_date.isoformat()
                },
                all_accounts=all_accounts_list
            )

        except HTTPException:
            raise
        except Exception as e:
            raise HTTPException(status_code=500, detail=f"Failed to get branch report: {str(e)}")

    def get_transaction_summary(self, request: TransactionSummaryRequest) -> AccountTransactionSummary:
        try:
            if not self.transaction_repo.account_exists(request.acc_id):
                raise HTTPException(status_code=404, detail="Account not found")

            summary_data = self.transaction_repo.calculate_daily_monthly_transaction_totals(
                acc_id=request.acc_id,
                period=request.period,
                start_date=request.start_date,
                end_date=request.end_date
            )

            summaries = []
            total_deposits = 0
            total_withdrawals = 0
            total_transactions = 0

            for data in summary_data:
                net_change = float(data['total_deposits']) - float(data['total_withdrawals'])
                if request.period == 'daily':
                    summaries.append(DailyTransactionSummary(
                        date=data['summary_date'],
                        total_deposits=float(data['total_deposits']),
                        total_withdrawals=float(data['total_withdrawals']),
                        transaction_count=data['transaction_count'],
                        net_change=net_change
                    ))
                else:
                    summaries.append(MonthlyTransactionSummary(
                        year=data['year'],
                        month=data['month'],
                        total_deposits=float(data['total_deposits']),
                        total_withdrawals=float(data['total_withdrawals']),
                        total_transfers=float(data['total_transfers']),
                        transaction_count=data['transaction_count'],
                        net_change=net_change,
                        opening_balance=None,  # optional, calculate if needed
                        closing_balance=None
                    ))

                total_deposits += float(data['total_deposits'])
                total_withdrawals += float(data['total_withdrawals'])
                total_transactions += data['transaction_count']

            total_summary = {
                'total_deposits': total_deposits,
                'total_withdrawals': total_withdrawals,
                'total_transactions': total_transactions,
                'net_change': total_deposits - total_withdrawals,
                'average_transaction': (total_deposits + total_withdrawals) / total_transactions if total_transactions > 0 else 0
            }

            return AccountTransactionSummary(
                acc_id=request.acc_id,
                period=request.period,
                summaries=summaries,
                total_summary=total_summary
            )

        except HTTPException:
            raise
        except Exception as e:
            raise HTTPException(status_code=500, detail=f"Failed to get transaction summary: {str(e)}")

    def get_transaction_analytics(self, acc_id: str, days: int = 30) -> TransactionAnalytics:
        """Get detailed analytics for an account"""
        try:
            # Validate account exists
            if not self.transaction_repo.account_exists(acc_id):
                raise HTTPException(status_code=404, detail="Account not found")

            # Get analytics data
            analytics_data = self.transaction_repo.get_transaction_analytics(acc_id, days)

            return TransactionAnalytics(
                acc_id=acc_id,
                total_transactions=analytics_data.get('total_transactions', 0),
                avg_transaction_amount=analytics_data.get('avg_amount', 0),
                largest_deposit={
                    'amount': analytics_data.get('max_deposit', 0),
                    'count': analytics_data.get('deposit_count', 0)
                },
                largest_withdrawal={
                    'amount': analytics_data.get('max_withdrawal', 0),
                    'count': analytics_data.get('withdrawal_count', 0)
                },
                most_active_day={
                    'date': analytics_data.get('most_active_date'),
                    'transaction_count': analytics_data.get('most_active_count', 0)
                },
                transaction_frequency={
                    'deposits': analytics_data.get('deposit_count', 0),
                    'withdrawals': analytics_data.get('withdrawal_count', 0)
                }
            )

        except HTTPException:
            raise
        except Exception as e:
            raise HTTPException(status_code=500, detail=f"Failed to get transaction analytics: {str(e)}")

    def get_transaction_by_id(self, transaction_id: str) -> TransactionResponse:
        """Get a specific transaction by ID"""
        try:
            transaction_data = self.transaction_repo.get_transaction_by_id(transaction_id)
            
            if not transaction_data:
                raise HTTPException(status_code=404, detail="Transaction not found")

            return TransactionResponse(
                transaction_id=transaction_data['transaction_id'],
                amount=float(transaction_data['amount']),
                acc_id=transaction_data['acc_id'],
                type=transaction_data['type'],
                description=transaction_data['description'],
                reference_no=transaction_data['reference_no'],
                created_at=transaction_data['created_at'],
                created_by=transaction_data['created_by']
            )

        except HTTPException:
            raise
        except Exception as e:
            raise HTTPException(status_code=500, detail=f"Failed to get transaction: {str(e)}")

    def get_branch_transactions_report(self, branch_id: str, start_date: date, end_date: date, transaction_type: str = None) -> Dict[str, Any]:
        """Get transaction report for a specific branch within a date range"""
        try:
            # Validate date range
            if start_date > end_date:
                raise HTTPException(status_code=400, detail="Start date must be before or equal to end date")
            
            # Get transactions from repository
            transactions = self.transaction_repo.get_branch_transactions_by_date_range(
                branch_id=branch_id,
                start_date=start_date,
                end_date=end_date,
                transaction_type=transaction_type
            )
            
            # Calculate summary statistics
            total_transactions = len(transactions)
            total_amount = sum(float(tx['amount']) for tx in transactions)
            
            # Group by transaction type
            type_summary = {}
            for tx in transactions:
                tx_type = tx['type']
                if tx_type not in type_summary:
                    type_summary[tx_type] = {
                        'count': 0,
                        'total_amount': 0.0
                    }
                type_summary[tx_type]['count'] += 1
                type_summary[tx_type]['total_amount'] += float(tx['amount'])
            
            return {
                'branch_id': branch_id,
                'start_date': start_date,
                'end_date': end_date,
                'transaction_type_filter': transaction_type,
                'total_transactions': total_transactions,
                'total_amount': total_amount,
                'type_summary': type_summary,
                'transactions': [
                    {
                        'transaction_id': str(tx['transaction_id']),
                        'amount': float(tx['amount']),
                        'acc_id': str(tx['acc_id']),
                        'account_no': int(tx['account_no']),
                        'type': tx['type'],
                        'description': tx['description'],
                        'reference_no': int(tx['reference_no']) if tx['reference_no'] else None,
                        'created_at': tx['created_at'],
                        'created_by': str(tx['created_by']) if tx['created_by'] else None,
                        'username': tx.get('username')
                    }
                    for tx in transactions
                ]
            }
        except HTTPException:
            raise
        except Exception as e:
            raise HTTPException(status_code=500, detail=f"Failed to get branch transaction report: {str(e)}")
        
    def get_users_branch_transactions_report(self, current_user: dict, start_date: date, end_date: date, transaction_type: str = None) -> Dict[str, Any]:
        """Get transaction report for the branch of the authenticated user within a date range"""
        
        # Extract branch_id from current_user
        branch_id = current_user.get("branch_id")
        if not branch_id:
            raise HTTPException(status_code=401, detail="Unauthorized or branch information missing")

        return self.get_branch_transactions_report(branch_id, start_date, end_date, transaction_type)       