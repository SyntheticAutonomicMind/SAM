#!/usr/bin/env python3
"""Test Python script"""

def hello_world():
    print("Hello from test_workspace!")
    return "TESTMARKER_PYTHON"

def calculate_sum(a, b):
    return a + b

if __name__ == "__main__":
    hello_world()
    print(f"Result: {calculate_sum(10, 20)}")
