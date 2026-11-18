#!/usr/bin/env python3
"""Make verification reports portable before sharing or committing them."""

import argparse
import glob
import json
from pathlib import Path
import re


ABSOLUTE = re.compile(
    r'(?<![A-Za-z0-9])(?:\\\\\?\\)?'
    r'(?:[A-Za-z]:[\\/]|/(?:Users|home|tmp|var/tmp|mnt)/)'
    r'''[^\s'"<>|:,;\])}]*'''
)


def portable_path(match):
    value = match.group().replace('\\', '/')
    value = re.sub(r'^/\?/|^//\?/', '', value)
    if re.search(r'/python(?:\d+(?:\.\d+)*)?(?:\.exe)?$', value, re.I):
        return 'python'
    for module in ('mbmot', 'moondeteval', 'moon-cv-geometry'):
        marker = '/' + module + '/'
        if marker in value:
            return '../' + module + '/' + value.split(marker, 1)[1]
    if '/moonground/' in value:
        return value.split('/moonground/', 1)[1] or '.'
    if re.search(r'/moonground/?$', value):
        return '.'
    if re.search(r'/moonground-moon-[^/]+/?$', value) or value.endswith('/toolchain'):
        return '${MOON_HOME}'
    for marker in ('/_build/', '/validation/', '/examples/', '/web/', '/.mooncakes/'):
        if marker in value:
            return marker[1:] + value.split(marker, 1)[1]
    isolated = re.search(r'/moonground-linux-[^/]+(?:/(.*))?$', value)
    if isolated:
        tail = isolated.group(1) or ''
        source = re.match(r'source(?:-v[0-9.]+)?(?:/(.*))?$', tail)
        if source:
            return source.group(1) or '.'
        return '<isolated-run>' + ('/' + tail if tail else '')
    if value.lower().endswith('.zip'):
        return '<registry-cache>/' + value.rsplit('/', 1)[-1]
    return '<local-environment>/' + value.rstrip('/').rsplit('/', 1)[-1]


def portable_text(value):
    parts = re.split(r'''(https?://[^\s<>"']+)''', value)
    result = ''.join(part if part.startswith(('http://', 'https://')) else ABSOLUTE.sub(portable_path, part)
                     for part in parts)
    if result == value:
        return value
    result = result.replace("'python'", 'python').replace('"python"', 'python')
    return result


def portable_report(value):
    if isinstance(value, str):
        return portable_text(value)
    if isinstance(value, list):
        return [portable_report(child) for child in value]
    if isinstance(value, dict):
        return {key: portable_report(child) for key, child in value.items()}
    return value


def normalize_document(source):
    """Replace JSON string tokens without reformatting numbers or other fields."""
    def replace(match):
        original = match.group()
        value = json.loads(original)
        normalized = portable_text(value)
        return json.dumps(normalized, ensure_ascii=True) if normalized != value else original
    return re.sub(r'"(?:[^"\\]|\\.)*"', replace, source)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('patterns', nargs='*', default=['validation/*results.json'])
    parser.add_argument('--check', action='store_true', help='report paths without writing files')
    args = parser.parse_args()
    paths = sorted({Path(name) for pattern in args.patterns for name in glob.glob(pattern)})
    changed = 0
    for path in paths:
        original = path.read_bytes().decode('utf-8')
        normalized = normalize_document(original)
        before = json.loads(original)
        after = json.loads(normalized)
        if after != portable_report(before):
            raise AssertionError('report fields changed unexpectedly: ' + str(path))
        if normalize_document(normalized) != normalized:
            raise AssertionError('normalization is not stable: ' + str(path))
        if normalized != original:
            changed += 1
            if not args.check:
                path.write_bytes(normalized.encode('utf-8'))
    print('reports={}, {}={}'.format(len(paths), 'paths_remaining' if args.check else 'normalized', changed))
    if args.check and changed:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
