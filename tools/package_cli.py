#!/usr/bin/env python3
"""Build a versioned CLI ZIP with payload hashes and recorded native dependencies."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import struct
import subprocess
import sys
import zipfile

import moonground_cli as installer

ROOT = Path(__file__).resolve().parent.parent


def pe_dependencies(binary):
    data = binary.read_bytes()
    pe = struct.unpack_from('<I', data, 60)[0]
    if data[pe:pe+6] != b'PE\x00\x00\x64\x86':
        raise ValueError('expected a Windows x86-64 executable')
    sections = struct.unpack_from('<H', data, pe+6)[0]
    optional_size = struct.unpack_from('<H', data, pe+20)[0]
    optional = pe+24
    if struct.unpack_from('<H', data, optional)[0] != 0x20b:
        raise ValueError('expected PE32+ optional header')
    import_rva = struct.unpack_from('<I', data, optional+120)[0]
    table = optional+optional_size
    def offset(rva):
        for i in range(sections):
            section = table+i*40
            virtual_size, address, raw_size, raw_pointer = struct.unpack_from('<IIII', data, section+8)
            if address <= rva < address+max(virtual_size, raw_size):
                result = raw_pointer+rva-address
                if result >= len(data):
                    break
                return result
        raise ValueError('invalid PE import address')
    pointer, result = offset(import_rva), []
    for _ in range(128):
        entry = struct.unpack_from('<IIIII', data, pointer)
        if entry == (0,0,0,0,0):
            return sorted(set(result), key=str.lower)
        start = offset(entry[3])
        end = data.find(b'\x00', start, start+256)
        if end < 0:
            raise ValueError('invalid PE dependency name')
        result.append(data[start:end].decode('ascii'))
        pointer += 20
    raise ValueError('too many PE imports')


def native_runtime(binary, target):
    if target == 'windows-x86_64':
        dependencies = pe_dependencies(binary)
        allowed = {'kernel32.dll','ws2_32.dll','dbghelp.dll','shell32.dll','bcrypt.dll',
                   'advapi32.dll','crypt32.dll','user32.dll','ole32.dll','ntdll.dll'}
        if any(name.lower() not in allowed for name in dependencies):
            raise ValueError('Windows release requires an unbundled non-system DLL: '+str(dependencies))
        return dict(minimum_os='Windows x86-64; validated on Windows 11 and Server 2022',
                    dependencies=dependencies, glibc_min=None)
    dynamic = subprocess.check_output(['readelf','-d',str(binary)], text=True, encoding='utf-8')
    dependencies = sorted(set(re.findall(r'\(NEEDED\).*?\[([^\]]+)\]', dynamic)))
    allowed = {'libc.so.6','libm.so.6','libdl.so.2','libpthread.so.0','librt.so.1',
               'libgcc_s.so.1','libssl.so.3','libcrypto.so.3'}
    if set(dependencies)-allowed:
        raise ValueError('Linux release has an undeclared runtime dependency: '+str(dependencies))
    symbols = subprocess.check_output(['readelf','--version-info',str(binary)], text=True, encoding='utf-8')
    versions = [tuple(map(int, value.split('.'))) for value in re.findall(r'Name: GLIBC_([0-9.]+)', symbols)]
    required = max(versions, default=(2,0))
    return dict(minimum_os='Linux x86-64 with glibc '+'.'.join(map(str, required))+' or newer',
                dependencies=dependencies, glibc_min='.'.join(map(str, required)))


def module_version(root=ROOT):
    value = re.findall(r'^version\s*=\s*"([^"]+)"\s*$', (root/'moon.mod').read_text(encoding='utf-8'), re.M)
    if len(value) != 1 or not installer.VERSION.fullmatch(value[0]):
        raise ValueError('module must have one semantic version')
    return value[0]


def create_bundle(binary, output, version, commit, dirty, runtime=None):
    target = installer.binary_target(binary)
    if target != installer.host_target():
        raise ValueError('package the binary on its native platform')
    installer.asset_name(version, target)
    installer.probe(binary, version)
    runtime = runtime or native_runtime(binary, target)
    executable = 'bin/moonground.exe' if target == 'windows-x86_64' else 'bin/moonground'
    payload = {
        executable: binary.read_bytes(),
        'moonground_cli.py': (ROOT/'tools/moonground_cli.py').read_bytes(),
        'LICENSE': (ROOT/'LICENSE').read_bytes(),
        'THIRD_PARTY_NOTICES.md': (ROOT/'THIRD_PARTY_NOTICES.md').read_bytes(),
        'THIRD_PARTY_LICENSES.txt': (ROOT/'docs/cli-third-party-licenses.txt').read_bytes(),
        'CLI_README.md': (ROOT/'docs/cli-distribution.md').read_bytes(),
    }
    forbidden = [str(ROOT.resolve()).encode('utf-8'), str(ROOT.resolve()).replace('\\','/').encode('utf-8')]
    if any(marker and marker in payload[executable] for marker in forbidden):
        raise ValueError('native executable contains the source checkout path; remove native symbols/debug info before packaging (Linux: strip --strip-all)')
    value = dict(schema_version=1, name='moonground', version=version, target=target,
                 source_commit=commit, source_dirty=dirty,
                 toolchain=subprocess.check_output(['moon','version','--all','--no-path'], text=True, encoding='utf-8').strip(),
                 executable=executable, runtime=runtime,
                 files={name:dict(sha256=hashlib.sha256(data).hexdigest(),size=len(data)) for name,data in payload.items()})
    installer.manifest(json.dumps(value).encode('utf-8'))
    payload['manifest.json'] = (json.dumps(value, indent=2)+'\n').encode('utf-8')
    output.mkdir(parents=True, exist_ok=True)
    archive = output/installer.asset_name(version, target)
    # Fixed entry timestamps/order/modes make the ZIP deterministic for identical
    # inputs. Native compiler reproducibility is a separate property.
    with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as package:
        for name,data in sorted(payload.items()):
            info = zipfile.ZipInfo(name, date_time=(1980,1,1,0,0,0))
            info.create_system = 3
            mode = 0o755 if name == executable or name == 'moonground_cli.py' else 0o644
            info.external_attr = (stat.S_IFREG | mode) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            package.writestr(info, data, compresslevel=9)
    digest = installer.digest_file(archive)
    (output/(archive.name+'.sha256')).write_bytes((digest+'  '+archive.name+'\n').encode('ascii'))
    return dict(archive=archive.name,sha256=digest,manifest=value)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=ROOT/'_build/cli-release')
    parser.add_argument('--release', action='store_true', help='require clean tracked and untracked source')
    args = parser.parse_args()
    try:
        dirty = bool(subprocess.check_output(['git','status','--porcelain'],cwd=str(ROOT)))
        if args.release and dirty:
            raise ValueError('release packaging requires a clean source checkout')
        commit = subprocess.check_output(['git','rev-parse','HEAD'],cwd=str(ROOT),text=True).strip()
        value = create_bundle(args.binary.resolve(), args.output.resolve(), module_version(), commit, dirty)
        if args.release and value['manifest']['target']=='linux-x86_64' and tuple(map(int,value['manifest']['runtime']['glibc_min'].split('.'))) > (2,35):
            raise ValueError('release Linux baseline must be built on glibc 2.35 or older')
        print(json.dumps(value, ensure_ascii=True))
    except (OSError, ValueError, subprocess.SubprocessError, struct.error) as error:
        parser.exit(2,str(error)+'\n')


if __name__ == '__main__':
    main()
