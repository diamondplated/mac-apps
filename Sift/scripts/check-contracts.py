#!/usr/bin/env python3
"""Reject formatter types and unreviewed optional-try sites in Swift source.

The baseline records existing debt, not proof that every swallowed failure is safe.
Duplicate sites are counted, so copying an allowed statement still fails review.
"""
import collections
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent.parent
# Keep string literals intact while discarding comments. Keeping strings is conservative:
# a formatter name in a literal must be reviewed rather than silently ignored.
TOKENS = re.compile(r'"""[\s\S]*?"""|"(?:\\.|[^"\\])*"|//[^\n]*|/\*[\s\S]*?\*/')
FORMATTERS = re.compile(r'\b(?:NumberFormatter|DateFormatter|ISO8601DateFormatter)\b')
OPTIONAL_TRY = re.compile(r'\btry\s*\?')


def code(text):
    return TOKENS.sub(lambda m: '\n' * m[0].count('\n') if m[0].startswith(('/',)) else m[0], text)


def inspect(root):
    sites = collections.Counter()
    errors = []
    for path in sorted((root / 'Sources').rglob('*.swift')):
        relative = path.relative_to(root).as_posix()
        for number, line in enumerate(code(path.read_text()).splitlines(), 1):
            if FORMATTERS.search(line):
                errors.append(f'{relative}:{number}: forbidden Foundation formatter')
            if relative.startswith(('Sources/SiftEngine/', 'Sources/SiftVerify/', 'Sources/DuckDBKit/')):
                count = len(OPTIONAL_TRY.findall(line))
                if count:
                    sites[(relative, line.strip())] += count
    # Engine/UI tests own sessions until scoped shutdown completes, before process exit can
    # destroy DuckDB's parser statics. Keep new tests from silently losing that ownership.
    for target in ('SiftEngineTests', 'SiftUITests'):
        for path in sorted((root / 'Tests' / target).rglob('*.swift')):
            text = code(path.read_text())
            for match in re.finditer(r'(?m)^[ \t]*@Test\b', text):
                if not re.match(r'\(\.engineLifetime\s*[,)]', text[match.end():]):
                    errors.append(f'{path.relative_to(root)}: test needs .engineLifetime scope')
    return sites, errors


def validate(root):
    actual, errors = inspect(root)
    entries = json.loads((root / 'scripts/optional-try-baseline.json').read_text())
    expected = collections.Counter()
    for entry in entries:
        if not entry['reason'].strip():
            errors.append('Every baseline site needs a reason.')
        expected[(entry['path'], entry['code'])] += entry['count']
    for (path, line), count in (actual - expected).items():
        errors.append(f'{path}: {count} unreviewed try?: {line}')
    for (path, line), count in (expected - actual).items():
        errors.append(f'{path}: remove {count} stale baseline entries: {line}')
    return errors


if __name__ == '__main__':
    errors = validate(ROOT)
    if errors:
        print('\n'.join(errors), file=sys.stderr)
        sys.exit(1)
    print('Sift source contracts passed.')
