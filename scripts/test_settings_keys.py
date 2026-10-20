#!/usr/bin/env python3
import os
import re
import sys

# Test script to enumerate setting keys from settings.h and confirm registered pages in page_*.cpp

SETTINGS_H = "base/applications/systemsettings/settings.h"
SETTINGS_DIR = "base/applications/systemsettings"

def extract_enum_keys(filepath):
    keys = []
    in_enum = False
    with open(filepath, 'r', encoding='utf-8') as f:
        for line in f:
            if "enum class PageId" in line:
                in_enum = True
                continue
            if in_enum:
                if "Count" in line or "};" in line:
                    break
                cleaned = line.strip().rstrip(',').strip()
                if cleaned and cleaned != "{" and not cleaned.startswith("//") and cleaned != "None":
                    keys.append(cleaned)
    return keys

def check_pages_coverage(keys):
    missing_coverage = []
    # Search all cpp files in systemsettings
    all_content = ""
    for r, _, files in os.walk(SETTINGS_DIR):
        for f in files:
            if f.endswith('.cpp'):
                with open(os.path.join(r, f), 'r', encoding='utf-8', errors='ignore') as page_f:
                    all_content += page_f.read() + "\n"

    for key in keys:
        pattern = re.compile(r'\bPageId::' + re.escape(key) + r'\b')
        if not pattern.search(all_content):
            missing_coverage.append(key)

    return missing_coverage

def main():
    root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    settings_h_path = os.path.join(root, SETTINGS_H)

    if not os.path.exists(settings_h_path):
        print(f"Error: {SETTINGS_H} not found")
        sys.exit(1)

    keys = extract_enum_keys(settings_h_path)
    print(f"Found {len(keys)} PageId setting keys.")

    missing = check_pages_coverage(keys)
    if missing:
        print(f"Error: The following setting keys have no registered UI page or handler: {missing}")
        sys.exit(1)
    else:
        print("Settings Key Coverage Test Passed: All PageId keys map to UI surfaces.")
        sys.exit(0)

if __name__ == '__main__':
    main()
