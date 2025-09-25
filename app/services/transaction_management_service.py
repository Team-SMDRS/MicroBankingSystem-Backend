from app.repositories.transaction_management_repo import TransactionManagementRepository
from app.schemas.transaction_management_schema import (
    DepositRequest, WithdrawRequest, TransactionResponse, TransactionStatusResponse,
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
    def __init__(self, transaction_repo: TransactionManagementRepository):
        self.transaction_repo = transaction_repo

    def process_deposit(self, request: DepositRequest, user_id: str) -> TransactionStatusResponse:
        """Process a deposit transaction"""
        try:
            # Get acc_id from account_no
            acc_id = self.transaction_repo.get_account_id_by_account_no(request.account_no)
            if not acc_id:
                raise HTTPException(status_code=404, detail=f"Account with number {request.account_no} not found")

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
                    message=f"Withdrawal of ${request.amount:.2f} processed successfully",
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

            # Get transactions and total count
            transactions_data, total_count = self.transaction_repo.get_transaction_history_by_account(
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
            if request.acc_id and not self.transaction_repo.account_exists(request.acc_id):
                raise HTTPException(status_code=404, detail="Account not found")

            # Get transactions
            transactions_data = self.transaction_repo.get_transaction_history_by_date_range(
                start_date=request.start_date,
                end_date=request.end_date,
                acc_id=request.acc_id,
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
                    created_by=tx['created_by']
                )
                for tx in transactions_data
            ]

            # Calculate summary
            total_deposits = sum(tx.amount for tx in transactions if tx.type == TransactionType.DEPOSIT)
            total_withdrawals = sum(tx.amount for tx in transactions if tx.type == TransactionType.WITHDRAWAL)
            total_transfers = sum(tx.amount for tx in transactions if tx.type == TransactionType.BANK_TRANSFER)

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
                limit=5,
                start_date=request.start_date,
                end_date=request.end_date
            )

            top_accounts_list = [
                {
                    'acc_id': acc['acc_id'],
                    'acc_holder_name': acc['acc_holder_name'],
                    'transaction_count': acc['transaction_count'],
                    'total_volume': float(acc['total_volume'])
                }
                for acc in top_accounts
            ]

            return BranchTransactionSummary(
                branch_id=request.branch_id,
                branch_name=report_data.get('branch_name'),
                total_deposits=report_data.get('total_deposits', 0),
                total_withdrawals=report_data.get('total_withdrawals', 0),
                total_transfers=report_data.get('total_transfers', 0),
                transaction_count=report_data.get('transaction_count', 0),
                date_range={
                    'start_date': request.start_date.isoformat(),
                    'end_date': request.end_date.isoformat()
                },
                top_accounts=top_accounts_list
            )

        except HTTPException:
            raise
        except Exception as e:
            raise HTTPException(status_code=500, detail=f"Failed to get branch report: {str(e)}")

    def get_transaction_summary(self, request: TransactionSummaryRequest) -> AccountTransactionSummary:
        """Get transaction summary for an account"""
        try:
            # Validate account exists
            if not self.transaction_repo.account_exists(request.acc_id):
                raise HTTPException(status_code=404, detail="Account not found")

            # Get summary data from repository
            summary_data = self.transaction_repo.calculate_daily_monthly_transaction_totals(
                acc_id=request.acc_id,
                period=request.period,
                start_date=request.start_date,
                end_date=request.end_date
            )

            # Convert to appropriate summary models
            summaries = []
            total_deposits = 0
            total_withdrawals = 0
            total_transactions = 0

            for data in summary_data:
                if request.period == 'daily':
                    summary = DailyTransactionSummary(
                        date=data.get('summary_date', date.today()),
                        total_deposits=float(data.get('total_deposits', 0)),
                        total_withdrawals=float(data.get('total_withdrawals', 0)),
                        transaction_count=data.get('transaction_count', 0),
                        net_change=float(data.get('total_deposits', 0)) - float(data.get('total_withdrawals', 0))
                    )
                else:  # monthly
                    summary = MonthlyTransactionSummary(
                        year=data.get('year', date.today().year),
                        month=data.get('month', date.today().month),
                        total_deposits=float(data.get('total_deposits', 0)),
                        total_withdrawals=float(data.get('total_withdrawals', 0)),
                        total_transfers=float(data.get('total_transfers', 0)),
                        transaction_count=data.get('transaction_count', 0),
                        net_change=float(data.get('total_deposits', 0)) - float(data.get('total_withdrawals', 0)),
                        opening_balance=float(data.get('opening_balance', 0)) if data.get('opening_balance') else None,
                        closing_balance=float(data.get('closing_balance', 0)) if data.get('closing_balance') else None
                    )

                summaries.append(summary)
                total_deposits += float(data.get('total_deposits', 0))
                total_withdrawals += float(data.get('total_withdrawals', 0))
                total_transactions += data.get('transaction_count', 0)

            # Calculate overall summary
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