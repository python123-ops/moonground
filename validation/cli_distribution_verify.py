#!/usr/bin/env python3
"""Exercise two real CLI binaries through verified installation and rollback."""

import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import queue
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import threading
import time
from unittest import mock
import zipfile

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT/'tools'))
import moonground_cli as manager
import package_cli as packager
from public_reports import portable_report


def execute(command, input=None, status=0, cwd=ROOT, timeout=180, env=None):
    result = subprocess.run(command, input=input, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            cwd=str(cwd), timeout=timeout, env=env)
    assert result.returncode == status, (command[:2], result.returncode, result.stderr.decode('utf-8','replace')[-4000:])
    return result.stdout


def json_lines(data):
    return [json.loads(line) for line in data.splitlines()]


def stream_fixture():
    header = dict(session_id='distribution-test',mode='ground',diagnostics=True)
    rows = [dict(timestamp_us=str(i*200000),observations=[dict(track_id=1,point=[i*0.2,0])]) for i in range(5)]
    return header, rows


def encode_records(rows):
    return ('\n'.join(json.dumps(row,separators=(',',':')) for row in rows)+'\n').encode('utf-8')


def candidate_binary(directory, current_version):
    source = directory/'candidate-source'
    source.mkdir()
    ignored = {'_build','.mooncakes','.git','examples','validation','web','tools','docs'}
    for item in ROOT.rglob('*'):
        relative = item.relative_to(ROOT)
        if any(part in ignored for part in relative.parts) or not item.is_file():
            continue
        if item.suffix != '.mbt' and item.name not in {'moon.mod','moon.pkg','README.mbt.md'}:
            continue
        target = source/relative
        target.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(item,target)
    version = current_version+'-rc.1'
    for name in ['moon.mod','cmd/main/version.mbt']:
        path = source/name
        text = path.read_text(encoding='utf-8')
        assert text.count('"'+current_version+'"')==1,name
        path.write_text(text.replace('"'+current_version+'"','"'+version+'"'),encoding='utf-8')
    execute(['moon','update'],cwd=source)
    execute(['moon','build','cmd/main','--target','native','--release','--strip','--deny-warn'],cwd=source)
    binary = source/'_build/native/release/build/cmd/main/main.exe'
    manager.probe(binary,version)
    return binary, version


def mutate_archive(original, destination, change):
    with zipfile.ZipFile(original) as package:
        entries = [(copy.copy(item),package.read(item)) for item in package.infolist()]
    entries = change(entries)
    with zipfile.ZipFile(destination,'w',compression=zipfile.ZIP_DEFLATED) as package:
        for item,data in entries:
            package.writestr(item,data)
    return manager.digest_file(destination)


def manifest_change(entries, change):
    for i,(item,data) in enumerate(entries):
        if item.filename=='manifest.json':
            value = json.loads(data)
            change(value)
            entries[i] = item,(json.dumps(value)+'\n').encode('utf-8')
    return entries


def read_line(process):
    result = queue.Queue()
    threading.Thread(target=lambda:result.put(process.stdout.readline()),daemon=True).start()
    line = result.get(timeout=15)
    assert line, 'managed CLI exited before its first stream frame'
    return json.loads(line)


def run_suite(binary):
    cases = []
    def passed(name):
        cases.append(dict(name=name,passed=True))
    version = packager.module_version()
    manager.probe(binary,version)
    assert execute([str(binary),'--version']).strip()==('moonground '+version).encode('ascii')
    passed('native-version-matches-module')
    target = manager.host_target()
    commit = subprocess.check_output(['git','rev-parse','HEAD'],cwd=str(ROOT),text=True).strip()
    runtime = packager.native_runtime(binary,target)
    with tempfile.TemporaryDirectory(prefix='moonground-cli-distribution-') as temporary:
        directory = Path(temporary)
        old_binary, old_version = candidate_binary(directory,version)
        old = packager.create_bundle(old_binary,directory/'old',old_version,commit,True,runtime)
        new = packager.create_bundle(binary,directory/'new',version,commit,
                                    bool(subprocess.check_output(['git','status','--porcelain'],cwd=str(ROOT))),runtime)
        repeated = packager.create_bundle(binary,directory/'repeat',version,commit,new['manifest']['source_dirty'],runtime)
        assert repeated['sha256']==new['sha256']
        passed('deterministic-zip-for-identical-inputs')
        old_archive,new_archive = directory/'old'/old['archive'],directory/'new'/new['archive']
        prefix = directory/'install space \u6d4b\u8bd5'
        prefix.mkdir()
        sentinel = prefix/'operator-notes.txt'
        sentinel.write_bytes(b'user-owned data')
        assert manager.status(prefix)['installed'] is False
        try:
            manager.rollback(prefix)
        except ValueError:
            pass
        else:
            raise AssertionError('first installation unexpectedly has a previous version')
        passed('empty-prefix-and-missing-rollback')
        initial = manager.install_archive(prefix,old_archive,old['sha256'])
        assert initial['version']==old_version and initial['previous'] is None
        passed('first-install-real-prerelease-candidate')
        manager.install_archive(prefix,old_archive,old['sha256'].upper())
        assert manager.status(prefix)['previous'] is None
        passed('idempotent-install-and-uppercase-offline-checksum')
        before = (prefix/'current.json').read_bytes()
        def rejected(name,archive,digest):
            try:
                manager.install_archive(prefix,archive,digest)
            except (ValueError,OSError,KeyError,zipfile.BadZipFile):
                pass
            else:
                raise AssertionError(name+' was accepted')
            assert (prefix/'current.json').read_bytes()==before,name
            assert manager.status(prefix)['version']==old_version,name
            assert not list((prefix/'versions').glob('.stage-*')),name
            passed(name)
        rejected('archive-digest-mismatch',new_archive,'0'*64)
        bad = directory/'bad.zip'
        def broken_payload(entries):
            return [(item,data+b'changed' if item.filename==new['manifest']['executable'] else data) for item,data in entries]
        rejected('payload-size-or-digest-mismatch',bad,mutate_archive(new_archive,bad,broken_payload))
        rejected('native-identity-mismatch',bad,mutate_archive(new_archive,bad,
            lambda e:manifest_change(e,lambda m:m.update(version='9.9.9'))))
        def truncated_binary(entries):
            data=b'MZ'
            entries=[(item,data if item.filename==new['manifest']['executable'] else payload)
                     for item,payload in entries]
            return manifest_change(entries,lambda m:m['files'][m['executable']].update(
                sha256=hashlib.sha256(data).hexdigest(),size=len(data)))
        rejected('truncated-native-header-rejected',bad,mutate_archive(new_archive,bad,truncated_binary))
        wrong = 'linux-x86_64' if target=='windows-x86_64' else 'windows-x86_64'
        rejected('manifest-target-mismatch',bad,mutate_archive(new_archive,bad,
            lambda e:manifest_change(e,lambda m:m.update(target=wrong))))
        rejected('boolean-schema-rejected',bad,mutate_archive(new_archive,bad,
            lambda e:manifest_change(e,lambda m:m.update(schema_version=True))))
        rejected('unknown-manifest-field',bad,mutate_archive(new_archive,bad,
            lambda e:manifest_change(e,lambda m:m.update(extra=1))))
        rejected('oversized-file-declaration',bad,mutate_archive(new_archive,bad,
            lambda e:manifest_change(e,lambda m:m['files'][m['executable']].update(size=manager.MAX_FILE+1))))
        def traversal(entries):
            for item,_ in entries:
                if item.filename=='LICENSE':item.filename='../escaped-license'
            return entries
        rejected('archive-traversal-member',bad,mutate_archive(new_archive,bad,traversal))
        assert not (prefix.parent/'escaped-license').exists()
        def duplicate(entries):
            entries.append((zipfile.ZipInfo('LICENSE'),b'duplicate'))
            return entries
        rejected('duplicate-archive-member',bad,mutate_archive(new_archive,bad,duplicate))
        def symbolic(entries):
            for item,_ in entries:
                if item.filename=='moonground_cli.py':
                    item.create_system=3
                    item.external_attr=(stat.S_IFLNK|0o777)<<16
            return entries
        rejected('archive-symbolic-link-member',bad,mutate_archive(new_archive,bad,symbolic))
        def wrong_machine(entries):
            payload = None
            for i,(item,data) in enumerate(entries):
                if item.filename==new['manifest']['executable']:
                    payload=bytearray(data)
                    if target=='windows-x86_64':
                        pe=struct.unpack_from('<I',payload,60)[0]
                        struct.pack_into('<H',payload,pe+4,0xaa64)
                    else:
                        struct.pack_into('<H',payload,18,183)
                    payload=bytes(payload)
                    entries[i]=item,payload
            return manifest_change(entries,lambda m:m['files'][m['executable']].update(sha256=hashlib.sha256(payload).hexdigest()))
        rejected('native-architecture-mismatch',bad,mutate_archive(new_archive,bad,wrong_machine))
        original_replace = os.replace
        def no_selection(source,destination):
            if Path(destination).name=='current.json':
                raise PermissionError('injected selection replacement failure')
            return original_replace(source,destination)
        with mock.patch.object(manager.os,'replace',side_effect=no_selection):
            rejected('selection-write-failure-keeps-old-version',new_archive,new['sha256'])
        assert not list(prefix.glob('.selection-*'))
        # Hold the real OS lock in a separate process, then verify it releases
        # automatically when that process exits.
        lock_code = ('import sys\nfrom pathlib import Path\nsys.path.insert(0,sys.argv[1])\n'
                     'import moonground_cli as m\nwith m.installation_lock(Path(sys.argv[2])):\n'
                     ' print("locked",flush=True)\n sys.stdin.read(1)\n')
        locker = subprocess.Popen([sys.executable,'-c',lock_code,str(ROOT/'tools'),str(prefix)],
                                  stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        try:
            assert read_line_text(locker).strip()==b'locked'
            rejected('concurrent-operation-rejected',new_archive,new['sha256'])
        finally:
            locker.communicate(input=b'x',timeout=15)
        passed('operating-system-lock-released-after-process-exit')
        command = [sys.executable,str(ROOT/'tools/moonground_cli.py'),'--prefix',str(prefix)]
        header, rows = stream_fixture()
        payload=encode_records([header]+rows)
        baseline=json_lines(execute([str(old_binary),'--stream'],input=payload))
        assert json_lines(execute(command+['run','--','--stream'],input=payload))==baseline
        passed('managed-stdio-and-native-protocol-parity')
        child = subprocess.Popen(command+['run','--','--stream'],stdin=subprocess.PIPE,
                                 stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        try:
            child.stdin.write(encode_records([header,rows[0]]))
            child.stdin.flush()
            first=read_line(child)
            installed=manager.install_archive(prefix,new_archive,new['sha256'])
            assert installed['version']==version
            rest,errors=child.communicate(input=encode_records(rows[1:]),timeout=30)
            assert child.returncode==0 and not errors
            assert [first]+json_lines(rest)==baseline
        finally:
            if child.poll() is None:
                child.communicate(timeout=15)
        passed('upgrade-preserves-running-old-process')
        assert execute(command+['run','--','--version']).strip()==('moonground '+version).encode()
        passed('upgrade-selects-new-binary')
        checkpoint=json.loads(execute(command+['run','--','--checkpoint'],input=encode_records([header]+rows[:3])))
        resumed=encode_records([dict(resume=checkpoint)]+rows[3:])
        expected=json_lines(execute(command+['run','--','--stream'],input=resumed))
        state_before=(prefix/'current.json').read_bytes()
        def collision(entries):
            altered=b'changed README\n'
            entries=[(item,altered if item.filename=='CLI_README.md' else data) for item,data in entries]
            return manifest_change(entries,lambda m:m['files']['CLI_README.md'].update(
                sha256=hashlib.sha256(altered).hexdigest(),size=len(altered)))
        digest=mutate_archive(new_archive,bad,collision)
        try:
            manager.install_archive(prefix,bad,digest)
        except ValueError:
            pass
        else:
            raise AssertionError('same version accepted different immutable payload')
        assert (prefix/'current.json').read_bytes()==state_before
        passed('same-version-different-build-rejected')
        child=subprocess.Popen(command+['run','--','--stream'],stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        try:
            child.stdin.write(encode_records([header,rows[0]]))
            child.stdin.flush()
            first=read_line(child)
            rolled=manager.rollback(prefix)
            assert rolled['version']==old_version
            rest,errors=child.communicate(input=encode_records(rows[1:]),timeout=30)
            assert child.returncode==0 and not errors and [first]+json_lines(rest)==baseline
        finally:
            if child.poll() is None:child.communicate(timeout=15)
        passed('rollback-preserves-running-new-process')
        assert json_lines(execute(command+['run','--','--stream'],input=resumed))==expected
        passed('checkpoint-created-before-rollback-resumes-after-rollback')
        execute(command+['run','--','--stream'],input=b'not-json\n',status=2)
        passed('managed-native-error-exit-code-preserved')
        manager.rollback(prefix)
        selected=manager.selection(prefix)
        current_manifest,current_path=manager.installed(prefix,selected['active'])
        previous_manifest,previous_path=manager.installed(prefix,selected['previous'])
        previous_file=previous_path/previous_manifest['executable']
        previous_data=previous_file.read_bytes()
        previous_file.write_bytes(previous_data+b'corrupt')
        before=(prefix/'current.json').read_bytes()
        try:
            manager.rollback(prefix)
        except ValueError:
            pass
        else:
            raise AssertionError('rollback activated a corrupt previous version')
        assert (prefix/'current.json').read_bytes()==before
        previous_file.write_bytes(previous_data)
        passed('corrupt-previous-version-blocks-rollback')
        current_file=current_path/current_manifest['executable']
        current_file.write_bytes(current_file.read_bytes()+b'corrupt')
        manager.rollback(prefix)
        assert manager.status(prefix)['version']==old_version
        passed('valid-previous-version-recovers-corrupt-active-binary')
        extra=previous_path/'bin/undeclared.dll'
        extra.write_bytes(b'extra')
        try:
            manager.status(prefix)
        except ValueError:
            pass
        else:
            raise AssertionError('undeclared installed payload was ignored')
        extra.unlink()
        passed('undeclared-installed-files-rejected')
        assert sentinel.read_bytes()==b'user-owned data'
        passed('operator-owned-files-preserved')
        # Launch the installed executable with no MoonBit or build-tool PATH.
        active=manager.status(prefix)['executable']
        clean=dict(os.environ)
        clean.pop('MOON_HOME',None)
        clean['PATH']=os.path.join(os.environ.get('SystemRoot','C:/Windows'),'System32') if os.name=='nt' else '/usr/bin:/bin'
        assert json.loads(execute([active,'--version-json'],env=clean))['version']==old_version
        passed('native-run-without-moonbit-or-compiler-path')
        return cases,dict(current_version=version,previous_candidate_version=old_version,
                          current_binary_sha256=manager.digest_file(binary),
                          previous_candidate_binary_sha256=manager.digest_file(old_binary),runtime=runtime,
                          archive_sha256=new['sha256'],archive_files=7)


def read_line_text(process):
    result=queue.Queue()
    threading.Thread(target=lambda:result.put(process.stdout.readline()),daemon=True).start()
    return result.get(timeout=15)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary',type=Path,required=True)
    parser.add_argument('--output',type=Path,default=ROOT/'validation/cli-distribution-results.json')
    args=parser.parse_args()
    started=time.perf_counter()
    cases,artifacts=run_suite(args.binary.resolve())
    result=dict(status='passed',target=manager.host_target(),cases=cases,case_count=len(cases),
                artifacts=artifacts,elapsed_seconds=time.perf_counter()-started,
                command='python '+' '.join(sys.argv),
                source_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                manager_sha256=hashlib.sha256((ROOT/'tools/moonground_cli.py').read_bytes()).hexdigest(),
                packager_sha256=hashlib.sha256((ROOT/'tools/package_cli.py').read_bytes()).hexdigest(),
                toolchain=subprocess.check_output(['moon','version','--all','--no-path'],text=True).strip())
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_bytes((json.dumps(portable_report(result),indent=2)+'\n').encode('utf-8'))
    print(json.dumps(dict(status='passed',target=result['target'],cases=len(cases))))


if __name__=='__main__':
    main()
