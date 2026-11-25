#!/usr/bin/env python3
"""Install, select and run verified MoonGround CLI versions in a user directory."""

import argparse
import contextlib
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import stat
import struct
import subprocess
import sys
import tempfile
import urllib.request
import urllib.parse
import zipfile

REPOSITORY = 'python123-ops/moonground'
VERSION = re.compile(r'(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?\Z')
SHA256 = re.compile(r'[0-9a-f]{64}\Z')
TARGETS = ('linux-x86_64', 'windows-x86_64')
MAX_ARCHIVE = 64 * 1024 * 1024
MAX_FILE = 32 * 1024 * 1024


def unique_fields(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('duplicate JSON field: ' + key)
        result[key] = value
    return result


def parse_json(data):
    def bad_constant(value):
        raise ValueError('invalid JSON constant: ' + value)
    return json.loads(data.decode('utf-8'), object_pairs_hook=unique_fields,
                      parse_constant=bad_constant)


def host_target():
    machine = platform.machine().lower()
    if machine not in ('amd64', 'x86_64'):
        raise ValueError('CLI binaries currently support x86-64 only')
    if sys.platform == 'win32':
        return 'windows-x86_64'
    if sys.platform.startswith('linux'):
        return 'linux-x86_64'
    raise ValueError('CLI binaries currently support Windows and Linux only')


def asset_name(version, target):
    if not isinstance(version, str) or len(version) > 64 or not VERSION.fullmatch(version) or target not in TARGETS:
        raise ValueError('invalid CLI version or target')
    return 'moonground-cli-{}-{}.zip'.format(version, target)


def digest_file(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def is_link(path):
    metadata = path.lstat()
    return stat.S_ISLNK(metadata.st_mode) or bool(
        getattr(metadata, 'st_file_attributes', 0) & getattr(stat, 'FILE_ATTRIBUTE_REPARSE_POINT', 0))


def regular_file(path):
    if not path.is_file() or is_link(path):
        raise ValueError('expected a regular file: ' + path.name)


def binary_target(path):
    with path.open('rb') as stream:
        header = stream.read(64)
        if len(header) < 64:
            raise ValueError('native executable header is truncated')
        if header[:4] == b'\x7fELF' and header[4:6] == b'\x02\x01' and struct.unpack_from('<H', header, 18)[0] == 62:
            return 'linux-x86_64'
        if header[:2] == b'MZ':
            offset = struct.unpack_from('<I', header, 60)[0]
            if offset > MAX_FILE - 6:
                raise ValueError('invalid PE header offset')
            stream.seek(offset)
            signature = stream.read(6)
            if signature == b'PE\x00\x00\x64\x86':
                return 'windows-x86_64'
    raise ValueError('unsupported or malformed native executable')


def manifest(data):
    value = parse_json(data)
    fields = {'schema_version', 'name', 'version', 'target', 'source_commit',
              'source_dirty', 'toolchain', 'executable', 'files', 'runtime'}
    if not isinstance(value, dict) or set(value) != fields:
        raise ValueError('unsupported CLI manifest fields')
    if type(value['schema_version']) is not int or value['schema_version'] != 1 or value['name'] != 'moonground':
        raise ValueError('unsupported CLI manifest schema or name')
    if not isinstance(value['version'], str) or len(value['version']) > 64 or not VERSION.fullmatch(value['version']):
        raise ValueError('invalid CLI manifest version')
    target = value['target']
    if target not in TARGETS:
        raise ValueError('unsupported CLI manifest target')
    executable = 'bin/moonground.exe' if target == 'windows-x86_64' else 'bin/moonground'
    expected = {executable, 'moonground_cli.py', 'LICENSE', 'THIRD_PARTY_NOTICES.md',
                'THIRD_PARTY_LICENSES.txt', 'CLI_README.md'}
    extended = expected | {'moonground_jobs.py', 'CLI_JOBS.md'}
    evaluation = extended | {'evaluate_measurements.py', 'CLI_EVALUATION.md'}
    if value['executable'] != executable or not isinstance(value['files'], dict) or set(value['files']) not in (expected, extended, evaluation):
        raise ValueError('unexpected CLI payload files')
    if not isinstance(value['source_commit'], str) or not re.fullmatch(r'[0-9a-f]{40}', value['source_commit']):
        raise ValueError('CLI source_commit must be a full commit hash')
    if type(value['source_dirty']) is not bool or not isinstance(value['toolchain'], str) or len(value['toolchain']) > 4096:
        raise ValueError('invalid CLI build metadata')
    total = 0
    for name, entry in value['files'].items():
        if not isinstance(entry, dict) or set(entry) != {'sha256', 'size'}:
            raise ValueError('invalid CLI payload digest entry')
        if not isinstance(entry['sha256'], str) or not SHA256.fullmatch(entry['sha256']):
            raise ValueError('invalid CLI payload SHA-256')
        if type(entry['size']) is not int or not 0 < entry['size'] <= MAX_FILE:
            raise ValueError('CLI payload file size exceeds its limit')
        total += entry['size']
    if total > 128 * 1024 * 1024:
        raise ValueError('CLI payload exceeds total size limit')
    runtime = value['runtime']
    if not isinstance(runtime, dict) or set(runtime) != {'minimum_os', 'dependencies', 'glibc_min'}:
        raise ValueError('invalid CLI runtime metadata')
    if not isinstance(runtime['minimum_os'], str) or len(runtime['minimum_os']) > 128:
        raise ValueError('invalid minimum OS label')
    if not isinstance(runtime['dependencies'], list) or len(runtime['dependencies']) > 32 or any(
            not isinstance(item, str) or not re.fullmatch(r'[A-Za-z0-9_.+-]{1,128}', item)
            for item in runtime['dependencies']):
        raise ValueError('invalid runtime dependency list')
    glibc = runtime['glibc_min']
    if glibc is not None and (not isinstance(glibc, str) or not re.fullmatch(r'[0-9]+\.[0-9]+', glibc)):
        raise ValueError('invalid glibc minimum')
    if target == 'windows-x86_64' and glibc is not None:
        raise ValueError('Windows manifest must not specify glibc')
    return value


def check_runtime(value):
    if value['target'] != host_target():
        raise ValueError('release target differs from this machine')
    minimum = value['runtime']['glibc_min']
    if minimum is not None:
        name, version = platform.libc_ver()
        if name != 'glibc' or not version or tuple(map(int, version.split('.'))) < tuple(map(int, minimum.split('.'))):
            raise ValueError('this binary requires glibc ' + minimum + ' or newer')


def probe(binary, version):
    if binary_target(binary) != host_target():
        raise ValueError('executable architecture differs from the manifest target')
    with tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as errors:
        result = subprocess.run([str(binary), '--version-json'], stdin=subprocess.DEVNULL,
                                stdout=output, stderr=errors, timeout=10)
        output.seek(0)
        errors.seek(0)
        data, diagnostic = output.read(65537), errors.read(4096)
    if result.returncode or diagnostic or len(data) > 65536:
        raise ValueError('CLI version probe failed: ' + diagnostic.decode('utf-8', 'replace'))
    value = parse_json(data)
    if value != {'name': 'moonground', 'version': version, 'measurement_schema_version': '0.2.0'}:
        raise ValueError('executable identity differs from its release manifest')


def atomic_write(path, data):
    temporary = None
    try:
        with tempfile.NamedTemporaryFile('wb', dir=str(path.parent), prefix='.selection-', delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(str(temporary), str(path))
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()


@contextlib.contextmanager
def installation_lock(root):
    root.mkdir(parents=True, exist_ok=True)
    lock = root / '.install.lock'
    if lock.exists() and is_link(lock):
        raise ValueError('installation lock must not be a link')
    with lock.open('a+b') as stream:
        stream.seek(0, 2)
        if stream.tell() == 0:
            stream.write(b'\x00')
            stream.flush()
        stream.seek(0)
        try:
            if os.name == 'nt':
                import msvcrt
                msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            raise ValueError('another installation operation holds this prefix') from error
        try:
            yield
        finally:
            stream.seek(0)
            if os.name == 'nt':
                import msvcrt
                msvcrt.locking(stream.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                import fcntl
                fcntl.flock(stream.fileno(), fcntl.LOCK_UN)


def selection(root):
    path = root / 'current.json'
    if not path.exists():
        return None
    regular_file(path)
    if path.stat().st_size > 16384:
        raise ValueError('installation selection is too large')
    value = parse_json(path.read_bytes())
    if not isinstance(value, dict) or set(value) != {'schema_version', 'target', 'active', 'previous'} or type(value['schema_version']) is not int or value['schema_version'] != 1:
        raise ValueError('unsupported installation selection')
    if value['target'] != host_target():
        raise ValueError('installation prefix belongs to another target')
    for key in ('active', 'previous'):
        slot = value[key]
        if key == 'previous' and slot is None:
            continue
        suffix = '-' + value['target']
        if not isinstance(slot, str) or not slot.endswith(suffix) or not VERSION.fullmatch(slot[:-len(suffix)]):
            raise ValueError('invalid installation version slot')
    if value['previous'] == value['active']:
        raise ValueError('active and previous selections must be distinct')
    return value


def installed(root, slot, health=False):
    versions = root / 'versions'
    if is_link(versions):
        raise ValueError('versions directory must not be a link')
    path = versions / slot
    if not path.is_dir() or is_link(path) or path.resolve().parent != versions.resolve():
        raise ValueError('installed version directory is missing or unsafe')
    regular_file(path/'manifest.json')
    if (path/'manifest.json').stat().st_size > 65536:
        raise ValueError('installed manifest exceeds its size limit')
    value = manifest((path/'manifest.json').read_bytes())
    if slot != value['version'] + '-' + value['target']:
        raise ValueError('installed version and manifest differ')
    check_runtime(value)
    if not (path/'bin').is_dir() or is_link(path/'bin'):
        raise ValueError('installed executable directory is unsafe')
    expected_names = {'manifest.json', 'bin'} | {name for name in value['files'] if '/' not in name}
    if {item.name for item in path.iterdir()} != expected_names or {item.name for item in (path/'bin').iterdir()} != {Path(value['executable']).name}:
        raise ValueError('installed directory contains undeclared payload files')
    for name, entry in value['files'].items():
        payload = path / name
        regular_file(payload)
        if payload.stat().st_size != entry['size'] or digest_file(payload) != entry['sha256']:
            raise ValueError('installed payload checksum differs: ' + name)
    if health:
        probe(path/value['executable'], value['version'])
    return value, path


def write_selection(root, active, previous):
    data = dict(schema_version=1, target=host_target(), active=active, previous=previous)
    atomic_write(root/'current.json', (json.dumps(data, indent=2)+'\n').encode('utf-8'))


def unpack_verified(archive, destination, expected_digest):
    regular_file(archive)
    if archive.stat().st_size > MAX_ARCHIVE or digest_file(archive) != expected_digest:
        raise ValueError('archive size or SHA-256 differs from the expected release')
    with zipfile.ZipFile(archive) as package:
        entries = package.infolist()
        if len(entries) not in (7, 9, 11) or len({entry.filename for entry in entries}) != len(entries):
            raise ValueError('unexpected or duplicate release archive members')
        metadata = package.getinfo('manifest.json')
        if metadata.file_size > 65536:
            raise ValueError('release manifest exceeds its size limit')
        value = manifest(package.read(metadata))
        check_runtime(value)
        if {entry.filename for entry in entries} != set(value['files']) | {'manifest.json'}:
            raise ValueError('archive members differ from its manifest')
        for entry in entries:
            kind = stat.S_IFMT(entry.external_attr >> 16)
            if entry.is_dir() or kind not in (0, stat.S_IFREG) or entry.flag_bits & 1:
                raise ValueError('release entries must be unencrypted regular files')
            if entry.filename != 'manifest.json' and entry.file_size != value['files'][entry.filename]['size']:
                raise ValueError('release entry size differs from its manifest')
            output = destination / entry.filename
            output.parent.mkdir(parents=True, exist_ok=True)
            with package.open(entry) as source, output.open('xb') as target:
                shutil.copyfileobj(source, target, 1024 * 1024)
                target.flush()
                os.fsync(target.fileno())
        binary = destination / value['executable']
        if os.name != 'nt':
            binary.chmod(0o755)
    return value


def install_archive(root, archive, expected_digest):
    if not isinstance(expected_digest, str) or not SHA256.fullmatch(expected_digest.lower()):
        raise ValueError('expected SHA-256 must contain 64 hexadecimal digits')
    expected_digest = expected_digest.lower()
    with installation_lock(root):
        before = selection(root)
        versions = root/'versions'
        versions.mkdir(exist_ok=True)
        if is_link(versions):
            raise ValueError('versions directory must not be a link')
        staging = Path(tempfile.mkdtemp(prefix='.stage-', dir=str(versions)))
        try:
            value = unpack_verified(archive, staging, expected_digest)
            slot = value['version'] + '-' + value['target']
            # Validate all staged files, including the manager and notices,
            # before any native program is executed or selection is changed.
            for name, entry in value['files'].items():
                if digest_file(staging/name) != entry['sha256']:
                    raise ValueError('staged payload checksum differs: ' + name)
            probe(staging/value['executable'], value['version'])
            destination = versions/slot
            if destination.exists():
                existing, _ = installed(root, slot, health=True)
                if existing != value:
                    raise ValueError('an immutable version slot already contains another build')
            else:
                os.rename(str(staging), str(destination))
            if before is None or before['active'] != slot:
                write_selection(root, slot, before['active'] if before else None)
            return status(root)
        finally:
            if staging.exists():
                if staging.resolve().parent != versions.resolve() or not staging.name.startswith('.stage-'):
                    raise ValueError('refusing to remove an unexpected staging directory')
                shutil.rmtree(staging)


def rollback(root):
    with installation_lock(root):
        before = selection(root)
        if before is None or before['previous'] is None:
            raise ValueError('no previous managed version is available')
        installed(root, before['previous'], health=True)
        write_selection(root, before['previous'], before['active'])
        return status(root)


def status(root):
    state = selection(root)
    if state is None:
        return dict(schema_version=1, installed=False, target=host_target())
    value, path = installed(root, state['active'])
    return dict(schema_version=1, installed=True, target=value['target'], version=value['version'],
                previous=state['previous'], executable=str(path/value['executable']),
                source_commit=value['source_commit'], binary_sha256=value['files'][value['executable']]['sha256'])


def download(url, destination, limit):
    request = urllib.request.Request(url, headers={'User-Agent': 'moonground-cli/1', 'Accept': 'application/octet-stream'})
    with urllib.request.urlopen(request, timeout=30) as source, destination.open('xb') as target:
        final = urllib.parse.urlparse(source.geturl())
        if final.scheme != 'https' or final.hostname not in {'github.com', 'objects.githubusercontent.com', 'release-assets.githubusercontent.com'}:
            raise ValueError('release download redirected outside GitHub HTTPS assets')
        total = 0
        while True:
            chunk = source.read(1024 * 1024)
            if not chunk:
                break
            total += len(chunk)
            if total > limit:
                raise ValueError('release download exceeds its size limit')
            target.write(chunk)


def remote_install(root, version):
    target = host_target()
    filename = asset_name(version, target)
    base = 'https://github.com/' + REPOSITORY + '/releases/download/v' + version + '/'
    with tempfile.TemporaryDirectory(prefix='moonground-cli-download-') as temporary:
        directory = Path(temporary)
        download(base+'SHA256SUMS', directory/'SHA256SUMS', 65536)
        sums = {}
        for line in (directory/'SHA256SUMS').read_text(encoding='ascii').splitlines():
            match = re.fullmatch(r'([0-9a-f]{64})  ([A-Za-z0-9_.-]+)', line)
            if not match or match[2] in sums:
                raise ValueError('invalid or duplicate release checksum entry')
            sums[match[2]] = match[1]
        if filename not in sums:
            raise ValueError('release has no checksum for this target')
        archive = directory/filename
        download(base+filename, archive, MAX_ARCHIVE)
        return install_archive(root, archive, sums[filename])


def run_selected(root, arguments):
    state = selection(root)
    if state is None:
        raise ValueError('no CLI version is installed')
    value, path = installed(root, state['active'])
    if arguments[:1] == ['--']:
        arguments = arguments[1:]
    child = subprocess.Popen([str(path/value['executable'])]+arguments)
    previous_handler = None
    if os.name != 'nt':
        previous_handler = signal.signal(signal.SIGTERM, lambda signum, frame: child.send_signal(signum))
    try:
        returncode = child.wait()
        return returncode if returncode >= 0 else 128-returncode
    except KeyboardInterrupt:
        child.terminate()
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()
        return 130
    finally:
        if previous_handler is not None:
            signal.signal(signal.SIGTERM, previous_handler)


def default_prefix():
    if os.name == 'nt':
        return Path(os.environ.get('LOCALAPPDATA', str(Path.home()/'AppData/Local')))/'MoonGround/cli'
    return Path.home()/'.local/share/moonground'


def job_module(root, capabilities=(), selected_only=False):
    state = selection(root)
    if state is None:
        raise ValueError('install a CLI release with durable replay support first')
    for slot in ([state['active']] if selected_only else [state['active'], state['previous']]):
        if slot is None:
            continue
        value, path = installed(root, slot)
        if 'moonground_jobs.py' in value['files']:
            spec = importlib.util.spec_from_file_location('moonground_durable_jobs', str(path/'moonground_jobs.py'))
            module = importlib.util.module_from_spec(spec)
            # The verified version directory is immutable; loading the helper
            # must not create an undeclared __pycache__ beside its payload.
            helper = path/'moonground_jobs.py'
            exec(compile(helper.read_bytes(), str(helper), 'exec'), module.__dict__)
            if all(hasattr(module, name) for name in capabilities):
                return module
    raise ValueError('installed releases do not contain the requested replay or state recovery support')


def evaluation_module(root, capabilities=(), selected_only=False):
    state = selection(root)
    if state is None:
        raise ValueError('install a CLI release with log evaluation support first')
    for slot in ([state['active']] if selected_only else [state['active'], state['previous']]):
        if slot is None:
            continue
        value, path = installed(root, slot)
        if 'evaluate_measurements.py' in value['files']:
            helper = path/'evaluate_measurements.py'
            spec = importlib.util.spec_from_file_location('moonground_log_evaluation', str(helper))
            module = importlib.util.module_from_spec(spec)
            exec(compile(helper.read_bytes(), str(helper), 'exec'), module.__dict__)
            if all(hasattr(module, name) for name in capabilities):
                return module
    raise ValueError('installed releases do not contain the requested log evaluation support')


def check_evaluation_destination(root, value):
    destination = Path(value).absolute()
    destination = destination.parent.resolve()/destination.name
    if destination in [root/'current.json', root/'.install.lock', root/'versions'] or root/'versions' in destination.parents or (
            destination == Path(__file__).resolve()) or (
            destination.exists() and os.path.samefile(destination, Path(__file__))):
        raise ValueError('evaluation output must be separate from installed versions, installation metadata and the manager')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prefix', type=Path, default=default_prefix())
    commands = parser.add_subparsers(dest='command', required=True)
    add = commands.add_parser('install', help='verify a release and activate it after a native version probe')
    source = add.add_mutually_exclusive_group(required=True)
    source.add_argument('--archive', type=Path)
    source.add_argument('--version')
    add.add_argument('--sha256')
    commands.add_parser('status')
    commands.add_parser('path')
    commands.add_parser('rollback')
    evaluate = commands.add_parser('evaluate', help='compare a log or committed replay with references; unmet requirements return 3')
    evaluation_source = evaluate.add_mutually_exclusive_group(required=True)
    evaluation_source.add_argument('--measurements')
    evaluation_source.add_argument('--state', help='read a checked SQLite replay snapshot without exporting it')
    evaluate.add_argument('--allow-partial', action='store_true')
    evaluate.add_argument('--max-state-mib', type=int, default=256)
    evaluate.add_argument('--state-timeout', type=float, default=60.0)
    evaluate.add_argument('--references', required=True)
    evaluate.add_argument('--requirements')
    evaluate.add_argument('--checkpoint',action='store_true')
    evaluate.add_argument('--committed-only', action='store_true', help='evaluate through the committed replay watermark; permits checked state continuation')
    evaluate.add_argument('--resume')
    evaluate.add_argument('--evaluation-state')
    evaluate.add_argument('--max-evaluation-mib', type=int)
    evaluate.add_argument('--evaluation-timeout', type=float)
    evaluate.add_argument('--session-id')
    evaluate.add_argument('--output')
    evaluate.add_argument('--max-tracks', type=int)
    evaluate.add_argument('--max-samples', type=int)
    evaluate.add_argument('--max-line-bytes', type=int, default=1048576)
    evaluate.add_argument('--timeout', type=float, default=300.0)
    for name in ['evaluation-status', 'evaluation-export', 'evaluation-backup', 'evaluation-restore']:
        operation = commands.add_parser(name)
        operation.add_argument('--evaluation-state', required=True)
        operation.add_argument('--max-evaluation-mib', type=int, default=256)
        operation.add_argument('--evaluation-timeout', type=float, default=60.0)
        if name == 'evaluation-export':
            operation.add_argument('--output', required=True)
            operation.add_argument('--sequence', type=int)
            operation.add_argument('--replace-existing', action='store_true')
        elif name == 'evaluation-backup':
            operation.add_argument('--output', required=True)
            operation.add_argument('--expected-report-sha256')
        elif name == 'evaluation-restore':
            operation.add_argument('--backup', required=True)
            operation.add_argument('--sha256', required=True)
    replay = commands.add_parser('replay', help='persist measurement results and checkpoints together')
    replay.add_argument('--input', required=True)
    replay.add_argument('--state', required=True)
    replay.add_argument('--batch-frames', type=int, default=128)
    replay.add_argument('--batch-bytes', type=int, default=4194304)
    replay.add_argument('--max-state-mib', type=int, default=256)
    replay.add_argument('--timeout-seconds', type=float, default=60.0)
    replay.add_argument('--max-frames', type=int)
    commands.add_parser('job-status').add_argument('--state', required=True)
    export = commands.add_parser('job-export')
    export.add_argument('--state', required=True)
    export.add_argument('--output', required=True)
    export.add_argument('--replace-existing', action='store_true')
    for name in ['job-verify', 'job-backup', 'job-restore']:
        operation = commands.add_parser(name)
        operation.add_argument('--state', required=True)
        operation.add_argument('--max-state-mib', type=int, default=256)
        operation.add_argument('--timeout-seconds', type=float, default=60.0)
        if name == 'job-backup':
            operation.add_argument('--output', required=True)
        if name == 'job-restore':
            operation.add_argument('--backup', required=True)
            operation.add_argument('--sha256', required=True)
    execute = commands.add_parser('run')
    execute.add_argument('arguments', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    root = args.prefix.expanduser().resolve()
    try:
        if args.command == 'evaluate':
            if args.allow_partial and args.state is None:
                raise ValueError('--allow-partial requires --state')
            if args.committed_only and args.state is None:
                raise ValueError('--committed-only requires --state')
            if args.resume is not None and args.state is not None and not args.committed_only:
                raise ValueError('--resume with --state requires --committed-only')
            if args.evaluation_state is not None and (args.state is None or not args.committed_only or args.resume is not None):
                raise ValueError('--evaluation-state requires --state --committed-only and replaces --resume')
            if args.evaluation_state is None and (args.max_evaluation_mib is not None or args.evaluation_timeout is not None):
                raise ValueError('evaluation state budgets require --evaluation-state')
            if args.output is not None:
                check_evaluation_destination(root, args.output)
            if args.evaluation_state is not None:
                for suffix in ['', '-journal', '-wal', '-shm', '.lock']:
                    check_evaluation_destination(root, args.evaluation_state+suffix)
            state = selection(root)
            if state is None:
                raise ValueError('install a CLI release before evaluating logs')
            value, path = installed(root, state['active'])
            if args.requirements is not None and 'evaluate_measurements.py' not in value['files']:
                raise ValueError('select a CLI release with measurement acceptance support')
            checkpoint_mode = args.checkpoint or args.resume is not None or args.committed_only
            capabilities = ('EVALUATION_STORE_VERSION',) if args.evaluation_state is not None else ('STATE_CONTINUATION_VERSION',) if args.committed_only else ('CHECKPOINT_INPUT_VERSION',) if checkpoint_mode else ('STATE_INPUT_VERSION',) if args.state is not None else ()
            module = evaluation_module(root, capabilities, selected_only=checkpoint_mode)
            measurement_source = None
            if args.state is not None:
                support = job_module(root, ('MeasurementSource', 'EVALUATION_STORE_VERSION') if args.evaluation_state is not None else ('MeasurementSource', 'STATE_CONTINUATION_VERSION') if args.committed_only else ('MeasurementSource',),
                                     selected_only=args.committed_only)
                measurement_source = support.MeasurementSource(Path(args.state), args.allow_partial,
                                                               args.max_state_mib, args.state_timeout)
            options = ['--binary', str(path/value['executable'])]
            for name in ['measurements', 'references', 'requirements', 'resume', 'session_id', 'output', 'max_tracks', 'max_samples', 'max_line_bytes', 'timeout']:
                if getattr(args, name) is not None:
                    options += ['--'+name.replace('_','-'), str(getattr(args, name))]
            if args.checkpoint:
                options += ['--checkpoint']
            if args.committed_only:
                options += ['--committed-only']
            if args.evaluation_state is not None:
                for name in ['evaluation_state', 'max_evaluation_mib', 'evaluation_timeout']:
                    if getattr(args, name) is not None:
                        options += ['--'+name.replace('_', '-'), str(getattr(args, name))]
            return module.main(options, measurement_source=measurement_source) if args.state is not None else module.main(options)
        if args.command in ('evaluation-status', 'evaluation-export', 'evaluation-backup', 'evaluation-restore'):
            if args.command in ('evaluation-export', 'evaluation-backup'):
                check_evaluation_destination(root, args.output)
            elif args.command == 'evaluation-restore':
                for suffix in ['', '-journal', '-wal', '-shm', '.lock']:
                    check_evaluation_destination(root, args.evaluation_state+suffix)
            capabilities = ('EvaluationStore', 'EVALUATION_SNAPSHOT_VERSION') if args.command in ('evaluation-backup', 'evaluation-restore') else ('EvaluationStore', 'EVALUATION_STORE_VERSION')
            module = job_module(root, capabilities)
            options = [args.command, '--evaluation-state', args.evaluation_state,
                       '--max-evaluation-mib', str(args.max_evaluation_mib), '--evaluation-timeout', str(args.evaluation_timeout)]
            if args.command == 'evaluation-export':
                options += ['--output', args.output]
                if args.sequence is not None:
                    options += ['--sequence', str(args.sequence)]
                if args.replace_existing:
                    options += ['--replace-existing']
            elif args.command == 'evaluation-backup':
                options += ['--output', args.output]
                if args.expected_report_sha256 is not None:
                    options += ['--expected-report-sha256', args.expected_report_sha256]
            elif args.command == 'evaluation-restore':
                options += ['--backup', args.backup, '--sha256', args.sha256]
            return module.main(options)
        if args.command in ('replay', 'job-status', 'job-export', 'job-verify', 'job-backup', 'job-restore'):
            capabilities = ('verify', 'backup', 'restore') if args.command in ('job-verify', 'job-backup', 'job-restore') else ()
            module = job_module(root, capabilities)
            options = ['--state', args.state]
            if args.command in ('job-verify', 'job-backup', 'job-restore'):
                options += ['--max-state-mib', str(args.max_state_mib), '--timeout-seconds', str(args.timeout_seconds)]
                if args.command == 'job-backup':
                    options += ['--output', args.output]
                elif args.command == 'job-restore':
                    options += ['--backup', args.backup, '--sha256', args.sha256]
                return module.main([args.command[4:]]+options)
            if args.command == 'replay':
                selected = selection(root)
                value, path = installed(root, selected['active'])
                if 'moonground_jobs.py' not in value['files']:
                    raise ValueError('select a CLI release with durable replay support')
                options += ['--binary', str(path/value['executable']), '--input', args.input]
                for name in ['batch_frames', 'batch_bytes', 'max_state_mib', 'timeout_seconds', 'max_frames']:
                    if getattr(args, name) is not None:
                        options += ['--'+name.replace('_', '-'), str(getattr(args, name))]
                return module.main(['run']+options)
            if args.command == 'job-export':
                options += ['--output', args.output]
                if args.replace_existing:
                    options += ['--replace-existing']
                return module.main(['export']+options)
            return module.main(['status']+options)
        if args.command == 'install':
            if args.archive:
                if args.sha256 is None:
                    raise ValueError('--archive requires --sha256 from the release checksum file')
                result = install_archive(root, args.archive.resolve(), args.sha256)
            else:
                if args.sha256 is not None:
                    raise ValueError('--sha256 is used with --archive; version downloads use SHA256SUMS')
                result = remote_install(root, args.version)
        elif args.command == 'rollback':
            result = rollback(root)
        elif args.command == 'run':
            return run_selected(root, args.arguments)
        elif args.command == 'path':
            result = status(root)
            if not result['installed']:
                raise ValueError('no CLI version is installed')
            print(result['executable'])
            return 0
        else:
            result = status(root)
        print(json.dumps(result, ensure_ascii=True, indent=2))
        return 0
    except (OSError, ValueError, KeyError, zipfile.BadZipFile, subprocess.TimeoutExpired) as error:
        parser.exit(2, str(error)+'\n')


if __name__ == '__main__':
    sys.exit(main())
