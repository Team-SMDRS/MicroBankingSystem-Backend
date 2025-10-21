# Branch Overview API - Data for Graphs and Charts

## New Endpoints Created

### 1. Get Branch Overview (with chart data)
**GET** `/api/overview/by-branch/{branch_id}`

**Parameters:**
- `branch_id` (path) - Unique branch identifier

**Response:**
Comprehensive dashboard data with multiple chart datasets:

```json
{
  "branch": {
    "id": "3dd6870c-e6f2-414d-9973-309ba00ce115",
    "name": "Colombo",
    "address": "123 Main Street"
  },
  "account_statistics": {
    "total_accounts": 150,
    "active_accounts": 145,
    "total_balance": 5000000.50,
    "average_balance": 33333.34
  },
  "accounts_by_plan": [
    {
      "plan_name": "Adult",
      "count": 80,
      "total_balance": 3000000.00
    },
    {
      "plan_name": "Joint",
      "count": 65,
      "total_balance": 2000000.50
    }
  ],
  "daily_transactions": [
    {
      "date": "2025-10-21",
      "count": 45,
      "amount": 150000.00
    },
    {
      "date": "2025-10-20",
      "count": 38,
      "amount": 120000.50
    }
  ],
  "transaction_types": [
    {
      "type": "Deposit",
      "count": 500,
      "total_amount": 2000000.00
    },
    {
      "type": "Withdrawal",
      "count": 350,
      "total_amount": 1500000.00
    },
    {
      "type": "BankTransfer-In",
      "count": 200,
      "total_amount": 800000.00
    },
    {
      "type": "BankTransfer-Out",
      "count": 150,
      "total_amount": 600000.00
    },
    {
      "type": "Interest",
      "count": 150,
      "total_amount": 50000.00
    }
  ],
  "account_status": [
    {
      "status": "active",
      "count": 145,
      "total_balance": 4900000.00
    },
    {
      "status": "frozen",
      "count": 4,
      "total_balance": 95000.00
    },
    {
      "status": "closed",
      "count": 1,
      "total_balance": 5000.50
    }
  ],
  "top_accounts": [
    {
      "account_no": "1111111111",
      "balance": 500000.00,
      "status": "active",
      "plan": "Adult"
    },
    {
      "account_no": "2222222222",
      "balance": 450000.00,
      "status": "active",
      "plan": "Joint"
    }
  ],
  "monthly_trend": [
    {
      "year": 2025,
      "month": 10,
      "transaction_count": 1200,
      "total_amount": 4500000.00
    },
    {
      "year": 2025,
      "month": 9,
      "transaction_count": 1100,
      "total_amount": 4200000.00
    }
  ],
  "weekly_interest": [
    {
      "week_start": "2025-10-20",
      "total_interest": 15000.00,
      "count": 50
    },
    {
      "week_start": "2025-10-13",
      "total_interest": 14000.00,
      "count": 48
    }
  ]
}
```

### 2. Branch Comparison
**GET** `/api/overview/branch-comparison`

**Response:**
Comparative data for all branches suitable for cross-branch analysis:

```json
{
  "branches": [
    {
      "branch_id": "3dd6870c-e6f2-414d-9973-309ba00ce115",
      "branch_name": "Colombo",
      "total_accounts": 150,
      "active_accounts": 145,
      "total_balance": 5000000.50,
      "total_transactions": 1200,
      "total_interest": 50000.00
    },
    {
      "branch_id": "branch-id-2",
      "branch_name": "Kandy",
      "total_accounts": 120,
      "active_accounts": 118,
      "total_balance": 4200000.00,
      "total_transactions": 1050,
      "total_interest": 42000.00
    }
  ],
  "total_all_branches": 9200000.50
}
```

## Chart Types & Data Mapping

### 1. **Pie Charts**
- **Accounts by Plan**: `accounts_by_plan` → count vs balance
- **Transaction Types**: `transaction_types` → count distribution
- **Account Status**: `account_status` → count distribution

### 2. **Bar/Column Charts**
- **Top Accounts**: `top_accounts` → horizontal bar chart
- **Daily Transactions**: `daily_transactions` → column chart (last 30 days)
- **Weekly Interest**: `weekly_interest` → bar chart
- **Branch Comparison**: `branches` → comparative bars across branches

### 3. **Line Charts**
- **Monthly Trend**: `monthly_trend` → line chart showing transaction volume/amount over 12 months
- **Daily Transactions**: `daily_transactions` → line chart for trends

### 4. **Summary Cards**
- Total Accounts: `account_statistics.total_accounts`
- Active Accounts: `account_statistics.active_accounts`
- Total Balance: `account_statistics.total_balance`
- Average Balance: `account_statistics.average_balance`

## Frontend Implementation Examples

### React/Chart.js Example for Pie Chart (Accounts by Plan):
```javascript
const chartData = {
  labels: data.accounts_by_plan.map(p => p.plan_name),
  datasets: [{
    data: data.accounts_by_plan.map(p => p.count),
    backgroundColor: ['#FF6384', '#36A2EB', '#FFCE56']
  }]
};
```

### React/Chart.js Example for Line Chart (Monthly Trend):
```javascript
const monthLabels = data.monthly_trend.map(t => `${t.month}/${t.year}`);
const amountData = data.monthly_trend.map(t => t.total_amount);
```

### React/Chart.js Example for Bar Chart (Transaction Types):
```javascript
const chartData = {
  labels: data.transaction_types.map(t => t.type),
  datasets: [{
    label: 'Transaction Count',
    data: data.transaction_types.map(t => t.count)
  }]
};
```

## API Integration Steps

1. **Call branch overview endpoint** with branch_id
2. **Extract relevant data** from response for your charts
3. **Map data** to your charting library (Chart.js, Recharts, etc.)
4. **Render charts** using the structured data

## Performance Notes

- Monthly trend data covers last 12 months
- Daily transactions cover last 30 days  
- Weekly interest covers last 8 weeks
- Top accounts limited to top 10 by balance
- All monetary values returned as floats
- Dates returned in ISO format

## Usage Tips

- Use `account_statistics` for summary KPI cards
- Use `accounts_by_plan` for pie chart showing account distribution
- Use `transaction_types` for transaction breakdown
- Use `daily_transactions` for real-time activity chart
- Use `monthly_trend` for historical analysis
- Use `weekly_interest` for interest tracking
- Use `top_accounts` for high-value customer identification
- Use branch comparison for multi-branch analysis
