#!/usr/bin/env python3
"""
Simple script to test if transaction management routes are properly imported
"""

try:
    from app.main import app
    print("✅ Main app imported successfully")
    
    # Get all routes
    routes = []
    for route in app.routes:
        if hasattr(route, 'methods') and hasattr(route, 'path'):
            for method in route.methods:
                if method != 'OPTIONS':  # Skip OPTIONS method
                    routes.append(f"{method} {route.path}")
    
    # Filter transaction routes
    transaction_routes = [route for route in routes if '/transactions' in route]
    
    print(f"\n📋 Found {len(transaction_routes)} transaction routes:")
    for route in sorted(transaction_routes):
        print(f"  - {route}")
    
    # Check specific balance route
    balance_route = "GET /api/transactions/account/{acc_id}/balance"
    if any("balance" in route for route in transaction_routes):
        print(f"\n✅ Balance endpoint found!")
    else:
        print(f"\n❌ Balance endpoint NOT found!")
        
    print(f"\n🌐 All available routes:")
    for route in sorted(routes):
        print(f"  - {route}")

except ImportError as e:
    print(f"❌ Import error: {e}")
except Exception as e:
    print(f"❌ Error: {e}")