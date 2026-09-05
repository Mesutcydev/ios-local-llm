#!/usr/bin/env python3
"""Bundle the licenses accompanying the native and Swift code in an IPA."""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parent.parent
app, log = Path(sys.argv[1]), Path(sys.argv[2])
paths = [root / 'LICENSE', root / 'THIRD_PARTY_NOTICES.md']
paths.extend(sorted((root / 'LICENSES').glob('*')))
for folder in ['LICENSES', 'Packages/VoiceAgentOrb', 'Packages/coreai-models',
               'ThirdParty/llama.cpp', 'ThirdParty/whisper.cpp', 'ThirdParty/thinking-orbs',
               'IOSLocalLLM/Vendor/StableDiffusion', 'IOSLocalLLM/Resources/Voice',
               'Pods/onnxruntime-c', 'Pods/onnxruntime-objc']:
    base = root / folder
    for pattern in ['LICENSE*', 'NOTICE*', 'COPYING*']:
        paths.extend(sorted(base.glob(pattern)))
checkouts = sorted(set(re.findall(r'(/[^\n" ]+/SourcePackages/checkouts)/', log.read_text())))
if not checkouts:
    raise SystemExit('No resolved package checkout paths found in archive log')
for location in checkouts:
    for package in sorted(Path(location).iterdir()):
        if package.is_dir():
            for pattern in ['LICENSE*', 'NOTICE*', 'COPYING*']:
                paths.extend(sorted(package.glob(pattern)))
sections = ['OnDevice Core — bundled third-party notices\n']
seen = set()
for path in paths:
    if not path.is_file() or path.resolve() in seen:
        continue
    seen.add(path.resolve())
    label = path.relative_to(root) if path.is_relative_to(root) else Path(path.parent.name) / path.name
    sections.append(f'\n=== {label} ===\n\n' + path.read_text(errors='replace'))
if len(seen) < 10:
    raise SystemExit('Incomplete license inventory')
(app / 'THIRD-PARTY-NOTICES.txt').write_text('\n'.join(sections))
print(f'Bundled {len(seen)} license and notice files')
