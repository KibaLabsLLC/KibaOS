#!/usr/bin/env python3
import os
import re
import sys

# Directories in scope for shell presentation token validation
SCOPE_DIRS = [
    "base/shell/explorer",
    "base/applications/systemsettings",
    "base/setup/welcome"
]

# Pattern matching hardcoded hex colors or direct raw RGB macros in presentation files
# that do NOT use UX_TOKEN_ prefix.
HEX_COLOR_PATTERN = re.compile(r'\b0x[0-9a-fA-F]{6}\b')
RAW_RGB_PATTERN = re.compile(r'\bRGB\s*\(\s*\d+\s*,\s*\d+\s*,\s*\d+\s*\)')

# List of files where legacy palette definitions / win32 theme colors are exempted
EXEMPT_FILES = [
    "base/shell/explorer/startmnu2.cpp",
    "base/shell/explorer/trayflyouts.cpp",
    "base/shell/explorer/taskswnd.cpp",
    "base/shell/explorer/util.cpp",
    "base/shell/explorer/traydeskbtn.cpp",
    "base/shell/explorer/traywnd.cpp",
    "base/shell/explorer/trayclock.cpp"
]

def scan_file(filepath, root):
    rel_path = os.path.relpath(filepath, root)
    if rel_path in EXEMPT_FILES:
        return []

    violations = []
    with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
        for idx, line in enumerate(f, 1):
            if "UX_TOKEN_" in line or "ux_tokens.h" in line or "// token-ignore" in line:
                continue
            if HEX_COLOR_PATTERN.search(line):
                violations.append((idx, line.strip(), "Hardcoded hex color without UX_TOKEN_"))
            elif RAW_RGB_PATTERN.search(line):
                violations.append((idx, line.strip(), "Hardcoded RGB literal without UX_TOKEN_"))
    return violations

def main():
    root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    total_violations = 0
    for rel_dir in SCOPE_DIRS:
        target_dir = os.path.join(root, rel_dir)
        if not os.path.exists(target_dir):
            continue
        for r, _, files in os.walk(target_dir):
            for file in files:
                if file.endswith(('.cpp', '.c', '.h')):
                    filepath = os.path.join(r, file)
                    violations = scan_file(filepath, root)
                    if violations:
                        print(f"Token violations in {os.path.relpath(filepath, root)}:")
                        for line_num, line_str, desc in violations:
                            print(f"  Line {line_num}: [{desc}] {line_str}")
                            total_violations += 1

    if total_violations > 0:
        print(f"\nTotal token violations found: {total_violations}")
        sys.exit(1)
    else:
        print("UX Token Check Passed: No hardcoded visual literals found in shell presentation directories.")
        sys.exit(0)

if __name__ == '__main__':
    main()
