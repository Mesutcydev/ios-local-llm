#!/usr/bin/env python3
"""Extract interface keys and validate bundled translations without network access.

This deliberately scans UI APIs and interface metadata, not prompts, chats,
model output, credentials, or arbitrary source literals.
"""
from __future__ import annotations

import argparse
from functools import lru_cache
import json
from pathlib import Path
import re
import sys
import textwrap

ROOT = Path(__file__).resolve().parents[1]
LANGUAGES = ['en', 'de', 'fr', 'es', 'pt', 'it', 'el', 'ro', 'ru', 'tr', 'ar', 'hi', 'zh-Hans', 'ja', 'ko']
TOKEN = re.compile(r'\{\{(\d+)\}\}')


def swift_string(source: str, start: int) -> tuple[str, int]:
    """Read one Swift string, preserving interpolations as numbered tokens."""
    triple = source.startswith('"""', start)
    quote = '"""' if triple else '"'
    hashes = 0
    while start - hashes - 1 >= 0 and source[start - hashes - 1] == '#': hashes += 1
    closing = quote + '#' * hashes
    escape = '\\' + '#' * hashes
    i = start + len(quote)
    result = []
    argument = 0
    while i < len(source):
        if source.startswith(closing, i):
            value = ''.join(result)
            if triple:
                value = textwrap.dedent(value.strip('\n'))
            return value, i + len(closing)
        if source.startswith(escape + '(', i):
            depth = 1
            i += len(escape) + 1
            while i < len(source) and depth:
                if source[i] == '"':
                    _, i = swift_string(source, i)
                    continue
                if source[i] == '(': depth += 1
                if source[i] == ')': depth -= 1
                i += 1
            result.append('{{' + str(argument) + '}}')
            argument += 1
            continue
        if source.startswith(escape, i) and i + len(escape) < len(source):
            escaped = source[i + len(escape)]
            if escaped == 'u' and source[i + len(escape) + 1:i + len(escape) + 2] == '{':
                end = source.index('}', i + len(escape) + 2)
                result.append(chr(int(source[i + len(escape) + 2:end], 16)))
                i = end + 1
            else:
                result.append({'n': '\n', 'r': '\r', 't': '\t', '0': '\0'}.get(escaped, escaped))
                i += len(escape) + 1
            continue
        result.append(source[i])
        i += 1
    raise ValueError(f'Unterminated Swift string at {start}')


def strings(source: str):
    i = 0
    while i < len(source):
        if source.startswith('//', i):
            end = source.find('\n', i)
            i = len(source) if end < 0 else end + 1
        elif source.startswith('/*', i):
            end = source.find('*/', i + 2)
            i = len(source) if end < 0 else end + 2
        elif source[i] == '"':
            value, end = swift_string(source, i)
            yield i, value, end
            i = end
        else:
            i += 1


def legacy_tables() -> dict[str, dict[str, str]]:
    source = (ROOT / 'IOSLocalLLM/Services/LocalizationService.swift').read_text()
    result = {}
    names = {'zh': 'zh-Hans'}
    for match in re.finditer(r'private static let (\w+)Entries:\s*\[\(String, String\)\]\s*=\s*\[', source):
        name = names.get(match[1], match[1])
        end = source.find('\n    ]', match.end())
        values = [value for _, value, _ in strings(source[match.end():end])]
        result[name] = dict(zip(values[::2], values[1::2]))
    return result


UI_CALL = re.compile(r'(?:\b(?:Text|Button|Label|Section|LabeledContent|TextField|SecureField|Toggle|Picker|KCaption|KMono|KPageTitle|L)\s*\(|ToastCenter\.shared\.(?:success|error|info|warning)\s*\(|\.(?:t|navigationTitle|accessibilityLabel|accessibilityHint|accessibilityValue|alert|confirmationDialog)\s*\()\s*$')
UI_ARGUMENT = re.compile(r'\b(?:title|subtitle|summary|label|text|detail|message|placeholder|eyebrow|caption|hint|description)\s*:\s*$')
PROPERTY = re.compile(r'\b(var|func)\s+(\w+)')
DISPLAY_PROPERTY = re.compile(r'title|label|displayName|subtitle|detail|status|message|description|reason|explanation|summary|shortName', re.I)
EXCLUDED_PROPERTY = re.compile(r'prompt|template|markdown|url|path|command|repo|identifier|systemImage|glyph|icon|asset', re.I)


def interface_keys() -> dict[str, list[str]]:
    keys: dict[str, list[str]] = {}
    paths = list((ROOT / 'IOSLocalLLM').rglob('*.swift')) + list((ROOT / 'IOSLocalLLMShareExtension').rglob('*.swift'))
    for path in sorted(paths):
        if any(part in path.parts for part in ['Vendor', 'LocalAIRuntimeFoundation']): continue
        if path.name == 'LocalizationService.swift': continue
        source = path.read_text()
        is_view = 'Views' in path.parts or path.name in ['ContentView.swift', 'ShareViewController.swift']
        for pos, value, _ in strings(source):
            prefix = source[max(0, pos - 140):pos]
            direct = UI_CALL.search(prefix) is not None or (is_view and re.search(r'(?:\b(?:Text|Button|Label|Toggle|L)|\.t)\([^\n]*[?:]\s*$', prefix) is not None)
            # UI status descriptors commonly return (SF Symbol, title, ...).
            # Capture the title, without cataloguing the icon or protocol data.
            if is_view and re.search(r'\breturn\s*\(\s*"[^"\n]+"\s*,\s*$', prefix): direct = True
            argument = is_view and UI_ARGUMENT.search(prefix) is not None
            if path.name in ['AssistantModelCatalog.swift', 'FastVLMConfig.swift', 'VoiceCatalog.swift', 'VoiceModelCatalog.swift', 'KittenVariant.swift', 'VoiceEngine.swift', 'ImageGenerationService.swift']:
                argument = argument or re.search(r'\b(?:subtitle|summary|detail|description)\s*:\s*$', prefix) is not None
            if path.name == 'VoiceCatalogStore.swift':
                argument = argument or re.search(r'\.(?:textToSpeech|speechRecognition)\s*,\s*$', prefix) is not None
            if path.name == 'ShareViewController.swift' and re.search(r'(?:message|error|description|NSLocalizedDescriptionKey):[^\n]{0,65}$', prefix): argument = True
            display_return = False
            if re.search(r'\breturn\s*$', prefix):
                properties = list(PROPERTY.finditer(source[:pos]))
                if properties:
                    kind, name = properties[-1].group(1, 2)
                    display_return = bool(DISPLAY_PROPERTY.search(name) and not EXCLUDED_PROPERTY.search(name))
                    if kind == 'func': display_return = bool(re.search(r'label|title|caption|hint|displayName', name, re.I))
            if re.search(r'\b(?:systemImage|systemName|image)\s*:\s*$', prefix): continue  # SF Symbol names are not interface text
            if not (direct or argument or display_return): continue
            if not re.search(r'[A-Za-z]', value) or not value.strip(): continue
            if value.startswith(('https://', 'http://', 'file://', 'data:')): continue
            if len(value) > 6000 or '\0' in value: continue
            line = source.count('\n', 0, pos) + 1
            keys.setdefault(value, []).append(f'{path.relative_to(ROOT)}:{line}')
    for table in legacy_tables().values():
        for key in table: keys.setdefault(key, ['legacy translation'])
    extras = ROOT / 'IOSLocalLLM/Resources/Localization/CompilerInterfaceKeys.json'
    if extras.exists():
        for entry in json.loads(extras.read_text()): keys.setdefault(entry['canonical'], [entry['source']])
    reviewed = ROOT / 'IOSLocalLLM/Resources/Localization/ReviewedTranslations.json'
    if reviewed.exists():
        for table in json.loads(reviewed.read_text()).values():
            for key in table: keys.setdefault(key, ['reviewed interface translation'])
    return dict(sorted(keys.items()))


def quoted(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def normalized(value: str) -> str:
    return ' '.join(value.replace('_', ' ').split()).casefold()


def native_entries(key: str, value: str):
    yield key, value
    for entry in compiler_entries().get(key, []):
        formats = entry['formats']
        native_key = entry['native']
        if not formats:
            yield native_key, value
            continue
        # The compiler supplies the exact interpolation type. Positional
        # arguments let translations reorder values without changing them.
        native_value = TOKEN.sub(lambda m: '%' + str(int(m[1]) + 1) + '$' + formats[int(m[1])], value)
        yield native_key, native_value


@lru_cache(maxsize=1)
def compiler_entries():
    path = ROOT / 'IOSLocalLLM/Resources/Localization/CompilerInterfaceKeys.json'
    result = {}
    for entry in json.loads(path.read_text()) if path.exists() else []:
        result.setdefault(entry['canonical'], []).append(entry)
    return result


def import_compiler_keys(directory: Path):
    entries = {}
    format_pattern = re.compile(r'%(?!%)(?:\d+\$)?(?:ll|l)?[@dDuUfFgGsS]')
    for path in directory.rglob('*.stringsdata'):
        data = json.loads(path.read_text())
        source = data.get('source', '')
        if not source.startswith(str(ROOT / 'IOSLocalLLM')): continue
        for row in data.get('tables', {}).get('Localizable', []):
            key = row['key']
            formats = []
            def marker(match):
                formats.append(re.sub(r'^%\d*\$?', '', match[0]))
                return '{{' + str(len(formats) - 1) + '}}'
            canonical = format_pattern.sub(marker, key).replace('%%', '%')
            if not re.search('[A-Za-z]', canonical): continue
            entries[key] = {'native': key, 'canonical': canonical, 'formats': formats, 'source': str(Path(source).relative_to(ROOT))}
    path = ROOT / 'IOSLocalLLM/Resources/Localization/CompilerInterfaceKeys.json'
    path.write_text(json.dumps(list(entries.values()), ensure_ascii=False, indent=2) + '\n')
    print(f'Imported {len(entries)} compiler-verified native interface keys.')


def export_tables(tables: dict[str, dict[str, str]], keys: list[str]):
    resources = ROOT / 'IOSLocalLLM/Resources/Localization'
    origins = interface_keys()
    share_keys = {key for key, places in origins.items() if any(place.startswith('IOSLocalLLMShareExtension/') for place in places)} | {'Done'}
    for language in LANGUAGES:
        table = tables[language]
        entries = {}
        for key in keys:
            value = table[key]
            if sorted(TOKEN.findall(key)) != sorted(TOKEN.findall(value)):
                raise ValueError(f'{language}: interpolation mismatch for {key!r}')
            for native_key, native_value in native_entries(key, value):
                entries[native_key] = native_value
        folder = resources / f'{language}.lproj'
        folder.mkdir(parents=True, exist_ok=True)
        header = '// Original app interface translations. Copyright 2026 Mesut and contributors; MIT.\n// Preserve interpolation tokens. Regenerate from the reviewed interface catalog.\n'
        content = '\n'.join(f'{quoted(k)} = {quoted(v)};' for k, v in sorted(entries.items())) + '\n'
        (folder / 'Localizable.strings').write_text(header + content)
        share = ROOT / 'IOSLocalLLMShareExtension/Resources' / f'{language}.lproj'
        share.mkdir(parents=True, exist_ok=True)
        (share / 'Localizable.strings').write_text(header + '\n'.join(f'{quoted(k)} = {quoted(table[k])};' for k in sorted(share_keys)) + '\n')
    manifest = {'languages': LANGUAGES, 'keys': keys, 'templates': [k for k in keys if TOKEN.search(k)]}
    (resources / 'InterfaceStringManifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')


def read_strings(path: Path):
    content = path.read_text()
    pair = re.compile(r'("(?:\\.|[^"\\])*" )', re.X)
    tokens = pair.findall('\n'.join(line for line in content.splitlines() if not line.startswith('//')))
    values = [json.loads(token) for token in tokens]
    return dict(zip(values[::2], values[1::2]))


def validate() -> bool:
    folder = ROOT / 'IOSLocalLLM/Resources/Localization'
    manifest = json.loads((folder / 'InterfaceStringManifest.json').read_text())
    expected = set(interface_keys())
    declared = set(manifest['keys'])
    missing = expected - declared
    failures = [f'Uncatalogued interface string: {key}' for key in sorted(missing)]
    for language in LANGUAGES:
        table = read_strings(folder / f'{language}.lproj/Localizable.strings')
        for key in declared:
            if not table.get(key): failures.append(f'{language}: missing {key}')
            elif sorted(TOKEN.findall(key)) != sorted(TOKEN.findall(table[key])):
                failures.append(f'{language}: invalid interpolation for {key}')
    if failures:
        print('\n'.join(failures[:50]), file=sys.stderr)
        print(f'{len(failures)} localization errors.', file=sys.stderr)
        return False
    print(f'Validated {len(declared)} interface keys across {len(LANGUAGES)} languages.')
    return True


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--extract', type=Path)
    parser.add_argument('--compiler-strings', type=Path)
    args = parser.parse_args()
    if args.compiler_strings: import_compiler_keys(args.compiler_strings)
    if args.extract:
        data = {'keys': interface_keys(), 'existing': legacy_tables(), 'languages': LANGUAGES}
        args.extract.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')
        print(f'Extracted {len(data["keys"])} interface keys; {len(data["existing"])} existing language tables.')
    elif not args.compiler_strings:
        sys.exit(0 if validate() else 1)
