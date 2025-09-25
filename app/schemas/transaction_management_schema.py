from pydantic import BaseModel, Field, validator
from typing import Optional, List, Dict, Any
from datetime import datetime, date
from enum import Enum
from decimal import Decimal

class TransactionType(str, Enum):
    DEPOSIT = "Deposit"
    WITHDRAWAL = "Withdrawal"
    INTEREST = "Interest"
    BANK_TRANSFER = "banktransfer"

# Base transaction models
class TransactionBase(BaseModel):
    amount: float = Field(..., gt=0, description="Transaction amount must be greater than 0")
    description: Optional[str] = Field(None, max_length=255, description="Transaction description")

class DepositRequest(TransactionBase):
    account_no: int = Field(..., description="Account Number to deposit to")
    
    @validator('amount')
    def validate_deposit_amount(cls, v):
        if v <= 0:
            raise ValueError('Deposit amount must be greater than 0')
        return v

class WithdrawRequest(TransactionBase):
    account_no: int = Field(..., description="Account Number to withdraw from")
    
    @validator('amount')
    def validate_withdraw_amount(cls, v):
        if v <= 0:
            raise ValueError('Withdrawal amount must be greater than 0')
        return v


# Transaction response models
class TransactionResponse(BaseModel):
    transaction_id: str
    amount: float
    acc_id: str
    type: TransactionType
    description: Optional[str]
    reference_no: Optional[int]
    created_at: datetime
    created_by: str
    balance_after: Optional[float] = Field(None, description="Account balance after transaction")

    class Config:
        from_attributes = True

class TransactionStatusResponse(BaseModel):
    success: bool
    message: str
    transaction_id: Optional[str] = None
    reference_no: Optional[int] = None  # Auto-generated reference number
    timestamp: datetime = Field(default_factory=datetime.now)

class AccountBalanceResponse(BaseModel):
    acc_id: str = Field(..., description="Account ID")
    account_no: Optional[int] = Field(None, description="Account number (bigint)")
    account_holder_name: Optional[str] = Field(None, description="Account holder's full name")
    balance: float = Field(..., description="Current account balance")
    message: str = Field(..., description="Response message")
    
    class Config:
        from_attributes = True

# Account transaction history
class AccountTransactionHistory(BaseModel):
    acc_id: str
    transactions: List[TransactionResponse]
    total_count: int
    page: int
    per_page: int
    total_pages: int
    current_balance: Optional[float] = None

# Date range query models
class DateRangeRequest(BaseModel):
    start_date: date = Field(..., description="Start date for the range (YYYY-MM-DD)")
    end_date: date = Field(..., description="End date for the range (YYYY-MM-DD)")
    acc_id: Optional[str] = Field(None, description="Optional account ID filter")
    transaction_type: Optional[TransactionType] = Field(None, description="Optional transaction type filter")
    
    @validator('end_date')
    def validate_date_range(cls, v, values):
        if 'start_date' in values and v < values['start_date']:
            raise ValueError('End date must be after start date')
        return v
    
    @validator('start_date')
    def validate_start_date_not_future(cls, v):
        if v > date.today():
            raise ValueError('Start date cannot be in the future')
        return v

class DateRangeTransactionResponse(BaseModel):
    transactions: List[TransactionResponse]
    total_count: int
    date_range: Dict[str, str]
    summary: Dict[str, Any]

# Branch report models
class BranchReportRequest(BaseModel):
    branch_id: str = Field(..., description="Branch ID for the report")
    start_date: date = Field(..., description="Start date for the report")
    end_date: date = Field(..., description="End date for the report")
    transaction_type: Optional[TransactionType] = Field(None, description="Optional transaction type filter")

class BranchTransactionSummary(BaseModel):
    branch_id: str
    branch_name: Optional[str]
    total_deposits: float
    total_withdrawals: float
    total_transfers: float
    transaction_count: int
    date_range: Dict[str, str]
    top_accounts: List[Dict[str, Any]]

# Transaction summary models
class TransactionSummaryRequest(BaseModel):
    acc_id: str = Field(..., description="Account ID for summary")
    period: str = Field(default="monthly", pattern="^(daily|weekly|monthly|yearly)$")
    start_date: Optional[date] = Field(None, description="Optional start date")
    end_date: Optional[date] = Field(None, description="Optional end date")

class DailyTransactionSummary(BaseModel):
    date: date
    total_deposits: float
    total_withdrawals: float
    transaction_count: int
    net_change: float

class MonthlyTransactionSummary(BaseModel):
    year: int
    month: int
    total_deposits: float
    total_withdrawals: float
    total_transfers: float
    transaction_count: int
    net_change: float
    opening_balance: Optional[float]
    closing_balance: Optional[float]

class AccountTransactionSummary(BaseModel):
    acc_id: str
    period: str
    summaries: List[DailyTransactionSummary | MonthlyTransactionSummary]
    total_summary: Dict[str, Any]

# Advanced analytics models
class TransactionAnalytics(BaseModel):
    acc_id: str
    total_transactions: int
    avg_transaction_amount: float
    largest_deposit: Dict[str, Any]
    largest_withdrawal: Dict[str, Any]
    most_active_day: Dict[str, Any]
    transaction_frequency: Dict[str, int]

class BulkTransactionRequest(BaseModel):
    transactions: List[DepositRequest | WithdrawRequest]
    
    @validator('transactions')
    def validate_bulk_limit(cls, v):
        if len(v) > 100:
            raise ValueError('Bulk transactions limited to 100 transactions per request')
        return v

class BulkTransactionResponse(BaseModel):
    total_requested: int
    successful: int
    failed: int
    results: List[TransactionStatusResponse]
    errors: List[Dict[str, Any]]

# Export models
class TransactionExportRequest(BaseModel):
    acc_id: Optional[str] = Field(None, description="Account ID filter")
    start_date: date = Field(..., description="Start date for export")
    end_date: date = Field(..., description="End date for export")
    format: str = Field(default="csv", pattern="^(csv|excel|pdf)$")
    include_balance: bool = Field(default=True, description="Include running balance")

class TransactionExportResponse(BaseModel):
    export_id: str
    status: str
    download_url: Optional[str]
    file_size: Optional[int]
    record_count: int
    created_at: datetime