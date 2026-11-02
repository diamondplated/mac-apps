#!/usr/bin/env python3
"""Mutation proofs in a disposable source tree; never edits the checkout."""
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile

spec = importlib.util.spec_from_file_location('contracts', Path(__file__).with_name('check-contracts.py'))
contracts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contracts)
with tempfile.TemporaryDirectory(prefix='sift-contracts-') as directory:
    root = Path(directory)
    shutil.copytree(contracts.ROOT / 'Sources', root / 'Sources')
    (root / 'scripts').mkdir()
    shutil.copyfile(contracts.ROOT / 'scripts/optional-try-baseline.json', root / 'scripts/optional-try-baseline.json')
    assert not contracts.validate(root)
    mutant = root / 'Sources/SiftEngine/ContractMutant.swift'
    mutant.write_text('// NumberFormatter is banned.\nlet formatter = NumberFormatter()\n')
    assert any('forbidden Foundation formatter' in e for e in contracts.validate(root))
    mutant.write_text('func mutant() { try? missingOperation() }\n')
    assert any('unreviewed try?' in e for e in contracts.validate(root))
    mutant.unlink()
    entry = json.loads((root / 'scripts/optional-try-baseline.json').read_text())[0]
    file = root / entry['path']
    file.write_text(file.read_text() + '\n' + entry['code'] + '\n')
    assert any('unreviewed try?' in e for e in contracts.validate(root))
print('Contract mutations detected: formatter, new try?, duplicated allowed try?.')
