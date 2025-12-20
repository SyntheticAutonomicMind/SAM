#!/usr/bin/env python3
"""
Test Python Script for MCP Testing
"""

def hello_world():
    """Simple test function"""
    print("Hello from test_workspace!")
    return True

def calculate_sum(a, b):
    """Calculate sum of two numbers"""
    return a + b

if __name__ == "__main__":
    hello_world()
    result = calculate_sum(10, 20)
    print(f"Result: {result}")
