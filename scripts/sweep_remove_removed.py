#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TARGET_DIRS = [ROOT / 'Sources', ROOT / 'Tests']

# Match block comments containing the word 'removed' (case-insensitive)
block_re = re.compile(r'/\*[\s\S]*?\*/', re.IGNORECASE)
# Match single-line comments containing the word 'removed'
single_re = re.compile(r'//+.*\bremoved\b.*', re.IGNORECASE)
# Match inline comment start position
inline_start_re = re.compile(r'//+')

changed_files = []

for base in TARGET_DIRS:
    if not base.exists():
        continue
    for path in base.rglob('*.swift'):
        text = path.read_text(encoding='utf-8')
        orig = text
        modified = False

        # Remove entire block comments that contain 'removed'
        def block_repl(m):
            content = m.group(0)
            if re.search(r'\bremoved\b', content, re.IGNORECASE):
                return ''
            return content

        text = block_re.sub(block_repl, text)

        # Process lines for single-line comments
        lines = text.splitlines()
        out_lines = []
        for line in lines:
            # If the line is a pure comment and contains removed -> drop
            stripped = line.lstrip()
            if stripped.startswith('//') and re.search(r'\bremoved\b', stripped, re.IGNORECASE):
                modified = True
                continue
            # Else check for inline comment containing removed
            if '//' in line and re.search(r'\bremoved\b', line, re.IGNORECASE):
                # Find the first '//' before the 'removed' occurrence
                m = re.search(r'\bremoved\b', line, re.IGNORECASE)
                if m:
                    rm_idx = m.start()
                    # find the comment start before rm_idx
                    comment_pos = line.rfind('//', 0, rm_idx)
                    if comment_pos != -1:
                        new_line = line[:comment_pos].rstrip()
                        # If nothing left on line, drop it entirely
                        if new_line.strip() == '':
                            modified = True
                            continue
                        out_lines.append(new_line)
                        modified = True
                        continue
            out_lines.append(line)

        new_text = '\n'.join(out_lines) + ("\n" if text.endswith('\n') else '')
        if new_text != orig:
            path.write_text(new_text, encoding='utf-8')
            changed_files.append(str(path.relative_to(ROOT)))

print('Modified files:')
for f in changed_files:
    print(f)
print('Total modified:', len(changed_files))
