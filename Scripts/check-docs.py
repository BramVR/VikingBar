#!/usr/bin/env python3
"""Validate repository-local Markdown links and required verification sections."""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
files = list(root.glob('*.md')) + list((root / 'docs').rglob('*.md'))
files += list((root / '.agents/skills').rglob('*.md'))
errors = []
for path in files:
    for target in re.findall(r'\]\(([^)]+)\)', path.read_text()):
        if '://' in target or target.startswith('#'):
            continue
        target = target.split('#')[0]
        if target and not (path.parent / target).exists():
            errors.append(f'{path.relative_to(root)}: missing {target}')
if errors:
    raise SystemExit('\n'.join(errors))
print(f'Documentation links passed ({len(files)} files).')
