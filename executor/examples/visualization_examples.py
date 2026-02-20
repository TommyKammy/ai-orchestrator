"""
Executor Sandbox Examples - Visualization
Phase 3: Example Usage

This file demonstrates how to use the sandbox with matplotlib
and other visualization libraries.
"""

import requests
import json
import base64

# API endpoint
EXECUTOR_URL = "http://localhost:8080"


def execute_code(code, template="python-data", files=None):
    """Helper function to execute code."""
    response = requests.post(
        f"{EXECUTOR_URL}/execute",
        json={
            "tenant_id": "example",
            "scope": "demo",
            "code": code,
            "template": template,
            "files": files or {}
        }
    )
    return response.json()


# Example 1: Simple Matplotlib Plot
example1_code = '''
import matplotlib.pyplot as plt
import numpy as np

# Generate data
x = np.linspace(0, 10, 100)
y = np.sin(x)

# Create plot
plt.figure(figsize=(8, 6))
plt.plot(x, y, 'b-', linewidth=2, label='sin(x)')
plt.title('Simple Sine Wave', fontsize=14)
plt.xlabel('x', fontsize=12)
plt.ylabel('sin(x)', fontsize=12)
plt.legend()
plt.grid(True, alpha=0.3)
plt.show()

print("Plot generated successfully!")
'''

print("Example 1: Simple Matplotlib Plot")
print("=" * 50)
result = execute_code(example1_code, template="python-data")
print(f"Status: {result['status']}")
print(f"Artifacts: {len(result.get('result', {}).get('artifacts', []))}")
if result['status'] == 'success':
    print("✓ Chart generated successfully")
print()


# Example 2: Multi-plot Dashboard
example2_code = '''
import matplotlib.pyplot as plt
import numpy as np

# Create figure with subplots
fig, axes = plt.subplots(2, 2, figsize=(12, 10))

# Data
x = np.linspace(0, 10, 100)

# Plot 1: Line chart
axes[0, 0].plot(x, np.sin(x), 'b-', label='sin(x)')
axes[0, 0].plot(x, np.cos(x), 'r--', label='cos(x)')
axes[0, 0].set_title('Trigonometric Functions')
axes[0, 0].legend()
axes[0, 0].grid(True, alpha=0.3)

# Plot 2: Bar chart
categories = ['A', 'B', 'C', 'D', 'E']
values = [23, 45, 56, 78, 32]
axes[0, 1].bar(categories, values, color='skyblue', edgecolor='navy')
axes[0, 1].set_title('Category Values')
axes[0, 1].set_ylabel('Value')

# Plot 3: Scatter plot
np.random.seed(42)
x_scatter = np.random.randn(100)
y_scatter = np.random.randn(100)
axes[1, 0].scatter(x_scatter, y_scatter, alpha=0.6, c='green')
axes[1, 0].set_title('Random Scatter Plot')
axes[1, 0].set_xlabel('X')
axes[1, 0].set_ylabel('Y')

# Plot 4: Histogram
data = np.random.normal(0, 1, 1000)
axes[1, 1].hist(data, bins=30, color='orange', edgecolor='black', alpha=0.7)
axes[1, 1].set_title('Normal Distribution')
axes[1, 1].set_xlabel('Value')
axes[1, 1].set_ylabel('Frequency')

plt.tight_layout()
plt.show()

print("Dashboard generated with 4 charts!")
'''

print("Example 2: Multi-plot Dashboard")
print("=" * 50)
result = execute_code(example2_code, template="python-data")
print(f"Status: {result['status']}")
if result['status'] == 'success':
    print("✓ Dashboard with 4 charts generated")
print()


# Example 3: Data Analysis with Pandas
example3_code = '''
import pandas as pd
import matplotlib.pyplot as plt
import numpy as np

# Create sample data
np.random.seed(42)
dates = pd.date_range('2024-01-01', periods=30, freq='D')
data = {
    'Date': dates,
    'Sales': np.random.randint(100, 500, 30),
    'Revenue': np.random.randint(1000, 5000, 30),
    'Customers': np.random.randint(50, 200, 30)
}

df = pd.DataFrame(data)

# Calculate moving averages
df['Sales_MA'] = df['Sales'].rolling(window=7).mean()

# Create visualization
fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(10, 8))

# Sales plot
ax1.plot(df['Date'], df['Sales'], 'b-', alpha=0.5, label='Daily Sales')
ax1.plot(df['Date'], df['Sales_MA'], 'r-', linewidth=2, label='7-day MA')
ax1.set_title('Sales Trend Analysis', fontsize=14)
ax1.set_ylabel('Sales')
ax1.legend()
ax1.grid(True, alpha=0.3)

# Revenue vs Customers scatter
ax2.scatter(df['Customers'], df['Revenue'], c='green', alpha=0.6, s=60)
ax2.set_title('Revenue vs Customers', fontsize=14)
ax2.set_xlabel('Number of Customers')
ax2.set_ylabel('Revenue ($)')
ax2.grid(True, alpha=0.3)

plt.tight_layout()
plt.show()

# Print summary statistics
print("\\n=== Summary Statistics ===")
print(df.describe().to_string())
print(f"\\nTotal Revenue: ${df['Revenue'].sum():,}")
print(f"Average Daily Sales: {df['Sales'].mean():.1f}")
'''

print("Example 3: Data Analysis with Pandas")
print("=" * 50)
result = execute_code(example3_code, template="python-data")
print(f"Status: {result['status']}")
if result['status'] == 'success':
    print("✓ Data analysis complete")
    print(result['result'].get('stdout', '')[-300:])  # Last 300 chars
print()


# Example 4: Using Persistent Session
print("Example 4: Persistent Session")
print("=" * 50)

# Create session
session_response = requests.post(
    f"{EXECUTOR_URL}/session/create",
    json={
        "tenant_id": "example",
        "scope": "demo-session",
        "template": "python-data",
        "ttl": 300
    }
)
session_data = session_response.json()
session_id = session_data.get('session_id')

print(f"Session created: {session_id}")

# Execute multiple commands in session
commands = [
    "import numpy as np; data = np.random.rand(100); print(f'Data mean: {data.mean():.4f}')",
    "import matplotlib.pyplot as plt; plt.hist(data, bins=20); plt.title('Data Distribution'); plt.show()",
    "print(f'Session still has data, std: {data.std():.4f}')"
]

for i, cmd in enumerate(commands, 1):
    result = requests.post(
        f"{EXECUTOR_URL}/session/execute",
        json={
            "session_id": session_id,
            "code": cmd
        }
    ).json()
    print(f"Command {i}: {result.get('status', 'unknown')}")

# Destroy session
requests.post(
    f"{EXECUTOR_URL}/session/destroy",
    json={"session_id": session_id}
)
print("✓ Session destroyed")
print()


print("=" * 50)
print("All examples completed successfully!")
print(f"API Endpoint: {EXECUTOR_URL}")
print("Templates available: /templates")
print("Metrics: /metrics")
