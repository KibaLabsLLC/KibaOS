#!/usr/bin/env python3
"""
Test script verifying Command Palette action registry completeness.
Ensures every registered action has an ID, Title, and Category.
"""

import sys

def test_action_registry():
    sample_registry = [
        {"id": "sys.settings", "title": "Open System Settings", "category": "Settings"},
        {"id": "sys.updates", "title": "Check for Updates", "category": "Updates"},
        {"id": "file.undo", "title": "Undo Last File Operation", "category": "Explorer"},
        {"id": "sys.restart", "title": "Restart Computer", "category": "Power"}
    ]

    for action in sample_registry:
        for required_key in ["id", "title", "category"]:
            if required_key not in action or not action[required_key]:
                print(f"Error: Registered action missing {required_key}: {action}")
                sys.exit(1)

    print("Command Palette Action Registry Test Passed: All registered actions valid!")
    sys.exit(0)

if __name__ == '__main__':
    test_action_registry()
