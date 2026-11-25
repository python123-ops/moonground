#!/usr/bin/env python3
"""Promote tested MoonGround CLI artifacts from a successful main-branch run."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

import moonground_cli as manager
import package_cli as packager

ROOT = Path(__file__).resolve().parent.parent


def gh(*arguments, missing=False):
    process = subprocess.run(['gh']+list(arguments),stdout=subprocess.PIPE,stderr=subprocess.PIPE,
                             text=True,encoding='utf-8',timeout=180)
    if process.returncode:
        if missing and 'HTTP 404' in process.stderr:
            return None
        raise ValueError(process.stderr.strip() or 'GitHub command failed')
    return process.stdout


def api(endpoint, method=None, body=None, missing=False):
    arguments=['api',endpoint]
    if method:arguments+=['--method',method]
    if body is None:return gh(*arguments,missing=missing)
    with tempfile.TemporaryDirectory(prefix='moonground-release-api-') as temporary:
        path=Path(temporary)/'request.json'
        path.write_text(json.dumps(body),encoding='utf-8')
        return gh(*(arguments+['--input',str(path)]),missing=missing)


def source_file(commit,name):
    if not re.fullmatch(r'[0-9a-f]{40}',commit):
        raise ValueError('release source must be a full commit hash')
    return subprocess.check_output(['git','show',commit+':'+name],cwd=str(ROOT))


def source(version,commit):
    if not manager.VERSION.fullmatch(version):
        raise ValueError('invalid release version')
    versions=re.findall(r'^version\s*=\s*"([^"]+)"\s*$',source_file(commit,'moon.mod').decode('utf-8'),re.M)
    if versions!=[version]:
        raise ValueError('requested release version differs from the source moon.mod')
    if subprocess.check_output(['git','status','--porcelain'],cwd=str(ROOT)):
        raise ValueError('release operations require a clean source checkout')
    if os.environ.get('GITHUB_REPOSITORY',manager.REPOSITORY)!=manager.REPOSITORY:
        raise ValueError('configure the release repository before publishing a fork')


def checked_run(version,commit):
    source(version,commit)
    runs=json.loads(gh('run','list','--repo',manager.REPOSITORY,'--workflow','ci.yml',
                       '--branch','main','--event','push','--commit',commit,'--limit','20',
                       '--json','databaseId,status,conclusion,headSha,url'))
    if not runs or runs[0]['headSha']!=commit or runs[0]['status']!='completed' or runs[0]['conclusion']!='success':
        raise ValueError('latest main-branch checks for this exact commit must finish successfully')
    return runs[0]


def inspect_archive(path):
    if path.stat().st_size>manager.MAX_ARCHIVE:
        raise ValueError('CLI archive exceeds its size limit')
    with zipfile.ZipFile(path) as archive:
        entries=archive.infolist()
        if len(entries) not in (7,9,11) or len({item.filename for item in entries})!=len(entries):
            raise ValueError('release archive has unexpected members')
        if archive.getinfo('manifest.json').file_size>65536:
            raise ValueError('release manifest exceeds its size limit')
        value=manager.manifest(archive.read('manifest.json'))
        if set(archive.namelist())!=set(value['files'])|{'manifest.json'}:
            raise ValueError('release archive differs from its manifest')
        for name,entry in value['files'].items():
            if archive.getinfo(name).file_size!=entry['size']:
                raise ValueError('release payload size differs: '+name)
            if hashlib.sha256(archive.read(name)).hexdigest()!=entry['sha256']:
                raise ValueError('release payload digest differs: '+name)
        script=archive.read('moonground_cli.py')
    return value,script


def require_state_recovery(recovery,stability,runner_digest,commit):
    if not recovery or recovery.get('status')!='passed' or not recovery.get('cases') or not all(case.get('passed') for case in recovery['cases']):
        raise ValueError('state backup verification did not pass for the released binary')
    if not stability or stability.get('status')!='passed' or stability.get('requested_seconds',0)<30 or stability.get('wall_seconds',0)<stability['requested_seconds']:
        raise ValueError('SQLite stability verification is missing or incomplete')
    if stability.get('completed_jobs',0)<2 or stability.get('backup_restore_cycles',0)<2 or stability.get('largest_sample_gap_seconds',61)>60:
        raise ValueError('SQLite stability verification lacks continuous replay and restore cycles')
    for result,name in [(recovery,'validation/cli_job_backup_verify.py'),(stability,'validation/cli_job_soak.py')]:
        if result.get('source_sha256')!=hashlib.sha256(source_file(commit,name)).hexdigest() or result.get('runner_sha256')!=runner_digest:
            raise ValueError('state recovery verification source differs from the tested commit')
    for key,name in [('sampler_sha256','validation/stream_test.py'),('support_sha256','validation/cli_jobs_verify.py')]:
        if stability.get(key)!=hashlib.sha256(source_file(commit,name)).hexdigest():
            raise ValueError('SQLite stability sampling source differs from the tested commit')


def require_measurement_acceptance(report,adapter_digest,commit):
    if not report or report.get('status')!='passed' or report.get('checks',0)<1:
        raise ValueError('measurement acceptance verification is missing or incomplete')
    for field in ['numerical_cases','protocol_cases','file_adapter_cases']:
        if not report.get(field) or not all(case.get('passed') for case in report[field]):
            raise ValueError('measurement acceptance verification cases did not all pass')
    for key,name in [('source_sha256','validation/measurement_acceptance_verify.py'),
                     ('reference_sha256','validation/measurement_evaluation_verify.py'),
                     ('adapter_sha256','examples/evaluate_measurements.py')]:
        if report.get(key)!=hashlib.sha256(source_file(commit,name)).hexdigest():
            raise ValueError('measurement acceptance verification source differs from the tested commit')
    if report['adapter_sha256']!=adapter_digest:
        raise ValueError('packaged evaluation adapter differs from the tested helper')
    web=report.get('web_interchange',{})
    if web.get('status')!='passed' or web.get('source_sha256')!=hashlib.sha256(source_file(commit,'web/measurement-acceptance.test.mjs')).hexdigest():
        raise ValueError('measurement acceptance interchange verification differs from the tested commit')


def require_sqlite_evaluation(report,binary_digest,files,commit):
    if not report or report.get('status')!='passed' or report.get('binary_sha256')!=binary_digest:
        raise ValueError('SQLite evaluation verification is missing or for a different binary')
    if not report.get('cases') or not all(case.get('passed') for case in report['cases']):
        raise ValueError('SQLite evaluation verification cases did not all pass')
    for key,name in [('source_sha256','validation/sqlite_evaluation_verify.py'),
                     ('runner_sha256','tools/moonground_jobs.py'),
                     ('adapter_sha256','examples/evaluate_measurements.py'),
                     ('manager_sha256','tools/moonground_cli.py'),
                     ('support_sha256','validation/cli_jobs_verify.py')]:
        if report.get(key)!=hashlib.sha256(source_file(commit,name)).hexdigest():
            raise ValueError('SQLite evaluation verification source differs from the tested commit')
    for key,name in [('runner_sha256','moonground_jobs.py'),('adapter_sha256','evaluate_measurements.py'),
                     ('manager_sha256','moonground_cli.py')]:
        if report[key]!=files[name]['sha256']:
            raise ValueError('SQLite evaluation helper differs from the tested payload')
    larger=report.get('larger_job',{})
    if larger.get('frames',0)<4096 or not 0<larger.get('python_peak_bytes',0)<8*1024*1024 or larger.get('logical_state_bytes',0)<=0:
        raise ValueError('SQLite evaluation bounded-memory run is missing or incomplete')


def require_evaluation_checkpoint(report,binary_digest,files,commit):
    if not report or report.get('status')!='passed' or report.get('binary_sha256')!=binary_digest:
        raise ValueError('evaluation checkpoint verification is missing or for a different binary')
    for key in ['numerical_cases','protocol_cases','file_adapter_cases']:
        if not report.get(key) or not all(case.get('passed') for case in report[key]):
            raise ValueError('evaluation checkpoint verification cases did not all pass')
    if report.get('checks',0)<1 or not 0<report.get('max_checkpoint_bytes',0)<=16384:
        raise ValueError('evaluation checkpoint population or size checks are incomplete')
    for key,name in [('source_sha256','validation/evaluation_checkpoint_verify.py'),
                     ('reference_sha256','validation/measurement_evaluation_verify.py'),
                     ('acceptance_reference_sha256','validation/measurement_acceptance_verify.py'),
                     ('adapter_sha256','examples/evaluate_measurements.py'),
                     ('manager_sha256','tools/moonground_cli.py'),('runner_sha256','tools/moonground_jobs.py'),
                     ('support_sha256','validation/cli_jobs_verify.py')]:
        if report.get(key)!=hashlib.sha256(source_file(commit,name)).hexdigest():
            raise ValueError('evaluation checkpoint verification source differs from the tested commit')
    for key,name in [('adapter_sha256','evaluate_measurements.py'),('manager_sha256','moonground_cli.py'),
                     ('runner_sha256','moonground_jobs.py')]:
        if report[key]!=files[name]['sha256']:
            raise ValueError('evaluation checkpoint helper differs from the tested payload')
    web=report.get('web_interchange',{})
    if web.get('status')!='passed' or web.get('source_sha256')!=hashlib.sha256(source_file(commit,'web/evaluation-checkpoint.test.mjs')).hexdigest():
        raise ValueError('evaluation checkpoint runtime interchange did not pass for this source')


def require_state_continuation(report,binary_digest,files,commit):
    if not report or report.get('status')!='passed' or report.get('binary_sha256')!=binary_digest:
        raise ValueError('state continuation verification is missing or for a different binary')
    if not report.get('cases') or not all(case.get('passed') for case in report['cases']):
        raise ValueError('state continuation cases did not all pass')
    if report.get('independent_statistics',{}).get('scalars',0)<1:
        raise ValueError('state continuation independent statistics are missing')
    for key,name in [('source_sha256','validation/state_continuation_verify.py'),
                     ('runner_sha256','tools/moonground_jobs.py'),('adapter_sha256','examples/evaluate_measurements.py'),
                     ('manager_sha256','tools/moonground_cli.py'),('support_sha256','validation/cli_jobs_verify.py'),
                     ('reference_sha256','validation/measurement_evaluation_verify.py')]:
        if report.get(key)!=hashlib.sha256(source_file(commit,name)).hexdigest():
            raise ValueError('state continuation verification source differs from the tested commit')
    for key,name in [('runner_sha256','moonground_jobs.py'),('adapter_sha256','evaluate_measurements.py'),
                     ('manager_sha256','moonground_cli.py')]:
        if report[key]!=files[name]['sha256']:
            raise ValueError('state continuation helper differs from the tested payload')


def require_evaluation_state(report,binary_digest,files,commit):
    if not report or report.get('status')!='passed' or report.get('binary_sha256')!=binary_digest:
        raise ValueError('durable evaluation state verification is missing or for a different binary')
    if not report.get('cases') or not all(case.get('passed') for case in report['cases']):
        raise ValueError('durable evaluation state cases did not all pass')
    if report.get('forced_commit_crashes',0)<2 or report.get('initialized_publication_failures',0)<2:
        raise ValueError('evaluation state crash and initialized-publication checks are incomplete')
    for key,name in [('source_sha256','validation/evaluation_state_verify.py'),
                     ('runner_sha256','tools/moonground_jobs.py'),('adapter_sha256','examples/evaluate_measurements.py'),
                     ('manager_sha256','tools/moonground_cli.py'),('support_sha256','validation/cli_jobs_verify.py')]:
        if report.get(key)!=hashlib.sha256(source_file(commit,name)).hexdigest():
            raise ValueError('evaluation state verification source differs from the tested commit')
    for key,name in [('runner_sha256','moonground_jobs.py'),('adapter_sha256','evaluate_measurements.py'),
                     ('manager_sha256','moonground_cli.py')]:
        if report[key]!=files[name]['sha256']:
            raise ValueError('evaluation state helper differs from the tested payload')


def require_evaluation_backup(report,binary_digest,files,commit):
    if not report or report.get('status')!='passed' or report.get('binary_sha256')!=binary_digest:
        raise ValueError('evaluation backup verification is missing or for a different binary')
    if not report.get('cases') or not all(case.get('passed') for case in report['cases']):
        raise ValueError('evaluation backup cases did not all pass')
    if report.get('forced_publication_crashes',0)<4 or report.get('wal_restoration') is not True:
        raise ValueError('evaluation backup crash and WAL restoration checks are incomplete')
    for key,name in [('source_sha256','validation/evaluation_backup_verify.py'),
                     ('runner_sha256','tools/moonground_jobs.py'),('adapter_sha256','examples/evaluate_measurements.py'),
                     ('manager_sha256','tools/moonground_cli.py'),('support_sha256','validation/cli_jobs_verify.py')]:
        if report.get(key)!=hashlib.sha256(source_file(commit,name)).hexdigest():
            raise ValueError('evaluation backup verification source differs from the tested commit')
    for key,name in [('runner_sha256','moonground_jobs.py'),('adapter_sha256','evaluate_measurements.py'),
                     ('manager_sha256','moonground_cli.py')]:
        if report[key]!=files[name]['sha256']:
            raise ValueError('evaluation backup helper differs from the tested payload')


def prepare(directory,output,version,commit,run_id):
    source(version,commit)
    archives=sorted(directory.rglob('moonground-cli-*.zip'))
    if len(archives)!=2:
        raise ValueError('one tested archive for each supported target is required')
    reports={}
    for path in directory.rglob('ci-cli-distribution.json'):
        value=json.loads(path.read_text(encoding='utf-8'))
        if value.get('target') in reports:
            raise ValueError('duplicate platform verification report')
        reports[value.get('target')]=value
    if set(reports)!=set(manager.TARGETS):
        raise ValueError('platform verification reports are missing')
    job_reports={}
    for path in directory.rglob('ci-cli-jobs.json'):
        value=json.loads(path.read_text(encoding='utf-8'))
        binary=value.get('binary_sha256')
        if binary in job_reports:
            raise ValueError('duplicate durable replay verification report')
        job_reports[binary]=value
    backup_reports={}
    soak_reports={}
    acceptance_reports={}
    sqlite_evaluation_reports={}
    evaluation_checkpoint_reports={}
    state_continuation_reports={}
    evaluation_state_reports={}
    evaluation_backup_reports={}
    for pattern,state_reports in [('ci-cli-job-backup.json',backup_reports),('ci-cli-job-soak/result.json',soak_reports),
                                 ('ci-measurement-acceptance.json',acceptance_reports),
                                 ('ci-sqlite-evaluation.json',sqlite_evaluation_reports),
                                 ('ci-evaluation-checkpoint.json',evaluation_checkpoint_reports),
                                 ('ci-state-continuation.json',state_continuation_reports),
                                 ('ci-evaluation-state.json',evaluation_state_reports),
                                 ('ci-evaluation-backup.json',evaluation_backup_reports)]:
        for path in directory.rglob(pattern):
            value=json.loads(path.read_text(encoding='utf-8'))
            binary=value.get('binary_sha256')
            if binary in state_reports:
                raise ValueError('duplicate state recovery verification report')
            state_reports[binary]=value
    output.mkdir(parents=True,exist_ok=True)
    artifacts={}
    script=None
    for path in archives:
        value,payload=inspect_archive(path)
        target=value['target']
        if target in artifacts or path.name!=manager.asset_name(version,target):
            raise ValueError('duplicate or misnamed release target')
        if value['version']!=version or value['source_commit']!=commit or value['source_dirty']:
            raise ValueError('release archive is not from the expected clean source commit')
        digest=manager.digest_file(path)
        expected=(path.parent/(path.name+'.sha256')).read_text(encoding='ascii')
        if expected!=digest+'  '+path.name+'\n':
            raise ValueError('build artifact checksum file differs')
        report=reports[target]
        if report.get('status')!='passed' or not report.get('cases') or not all(case.get('passed') for case in report['cases']):
            raise ValueError('platform distribution verification did not pass')
        tested=report['artifacts']
        if tested['archive_sha256']!=digest or tested['current_version']!=version or tested['current_binary_sha256']!=value['files'][value['executable']]['sha256']:
            raise ValueError('release bytes differ from the actual tested package')
        for key,name in [('manager_sha256','tools/moonground_cli.py'),('packager_sha256','tools/package_cli.py'),
                         ('source_sha256','validation/cli_distribution_verify.py')]:
            if report[key]!=hashlib.sha256(source_file(commit,name)).hexdigest():
                raise ValueError('distribution verification source differs from the tested commit')
        replay=None
        if 'moonground_jobs.py' in value['files']:
            replay=job_reports.get(tested['current_binary_sha256'])
            if not replay or replay.get('status')!='passed' or not replay.get('cases') or not all(case.get('passed') for case in replay['cases']):
                raise ValueError('durable replay verification did not pass for the released binary')
            for key,name in [('runner_sha256','tools/moonground_jobs.py'),('source_sha256','validation/cli_jobs_verify.py')]:
                if replay[key]!=hashlib.sha256(source_file(commit,name)).hexdigest():
                    raise ValueError('durable replay verification source differs from the tested commit')
            if replay['runner_sha256']!=value['files']['moonground_jobs.py']['sha256']:
                raise ValueError('durable replay helper differs from the tested payload')
            soak=replay.get('soak',{})
            if soak.get('status')!='passed' or soak.get('requested_seconds',0)<30 or soak.get('wall_seconds',0)<soak['requested_seconds']:
                raise ValueError('continuous stream verification is missing or incomplete')
            report=dict(report,durable_replay=replay)
            if b'\ndef backup(' in source_file(commit,'tools/moonground_jobs.py'):
                if replay.get('sampler_sha256')!=hashlib.sha256(source_file(commit,'validation/stream_test.py')).hexdigest():
                    raise ValueError('continuous stream sampling source differs from the tested commit')
                recovery=backup_reports.get(tested['current_binary_sha256'])
                stability=soak_reports.get(tested['current_binary_sha256'])
                require_state_recovery(recovery,stability,replay['runner_sha256'],commit)
                report=dict(report,state_recovery=recovery,sqlite_stability=stability)
        if 'evaluate_measurements.py' in value['files']:
            acceptance=acceptance_reports.get(tested['current_binary_sha256'])
            require_measurement_acceptance(acceptance,value['files']['evaluate_measurements.py']['sha256'],commit)
            report=dict(report,measurement_acceptance=acceptance)
            if b'\nclass MeasurementSource:' in source_file(commit,'tools/moonground_jobs.py'):
                evaluation=sqlite_evaluation_reports.get(tested['current_binary_sha256'])
                require_sqlite_evaluation(evaluation,tested['current_binary_sha256'],value['files'],commit)
                report=dict(report,sqlite_evaluation=evaluation)
            if b'\nCHECKPOINT_INPUT_VERSION = 1' in source_file(commit,'examples/evaluate_measurements.py'):
                checkpoint=evaluation_checkpoint_reports.get(tested['current_binary_sha256'])
                require_evaluation_checkpoint(checkpoint,tested['current_binary_sha256'],value['files'],commit)
                report=dict(report,evaluation_checkpoint=checkpoint)
            if b'\nSTATE_CONTINUATION_VERSION = 1' in source_file(commit,'examples/evaluate_measurements.py'):
                continuation=state_continuation_reports.get(tested['current_binary_sha256'])
                require_state_continuation(continuation,tested['current_binary_sha256'],value['files'],commit)
                report=dict(report,state_continuation=continuation)
            if b'\nEVALUATION_STORE_VERSION = 1' in source_file(commit,'examples/evaluate_measurements.py'):
                stored=evaluation_state_reports.get(tested['current_binary_sha256'])
                require_evaluation_state(stored,tested['current_binary_sha256'],value['files'],commit)
                report=dict(report,evaluation_state=stored)
            if b'\nEVALUATION_SNAPSHOT_VERSION = 1' in source_file(commit,'tools/moonground_jobs.py'):
                snapshot=evaluation_backup_reports.get(tested['current_binary_sha256'])
                require_evaluation_backup(snapshot,tested['current_binary_sha256'],value['files'],commit)
                report=dict(report,evaluation_backup=snapshot)
        if script is not None and payload!=script:
            raise ValueError('platform archives contain different manager scripts')
        script=payload
        shutil.copyfile(path,output/path.name)
        (output/('verification-'+target+'.json')).write_bytes((json.dumps(report,indent=2)+'\n').encode('utf-8'))
        artifacts[target]=dict(filename=path.name,sha256=digest,binary_sha256=tested['current_binary_sha256'],
                               runtime=value['runtime'])
    if set(artifacts)!=set(manager.TARGETS):
        raise ValueError('release target matrix is incomplete')
    (output/'moonground_cli.py').write_bytes(script)
    index=dict(schema_version=1,name='moonground',version=version,source_commit=commit,
               ci_run_id=run_id,ci_url='https://github.com/'+manager.REPOSITORY+'/actions/runs/'+str(run_id),
               artifacts=artifacts,manager_sha256=hashlib.sha256(script).hexdigest())
    (output/'RELEASE_MANIFEST.json').write_bytes((json.dumps(index,indent=2)+'\n').encode('utf-8'))
    names=sorted([item.name for item in output.iterdir() if item.is_file() and item.name!='SHA256SUMS'])
    expected={manager.asset_name(version,target) for target in manager.TARGETS}|{
        'verification-'+target+'.json' for target in manager.TARGETS}|{'moonground_cli.py','RELEASE_MANIFEST.json'}
    if set(names)!=expected:
        raise ValueError('release output contains unexpected files')
    (output/'SHA256SUMS').write_bytes((''.join(manager.digest_file(output/name)+'  '+name+'\n' for name in names)).encode('ascii'))
    notes=('MoonGround CLI '+version+'\n\n'
           'Windows x86-64 与 Linux x86-64 的预编译命令行程序，附校验文件、安装与回退管理脚本及两平台验证记录。\n\n'
           '安装：`python moonground_cli.py --prefix ./moonground-install install --version '+version+'`\n\n'
           '回退：`python moonground_cli.py --prefix ./moonground-install rollback`\n\n'
           '原生程序无需 MoonBit 或编译器，管理脚本使用 Python 3.8+。系统库条件记录在各包的 manifest.json。\n\n'
           '[安装说明](https://github.com/'+manager.REPOSITORY+'/blob/v'+version+'/docs/cli-distribution.md) · '
           '[源码提交](https://github.com/'+manager.REPOSITORY+'/commit/'+commit+') · '
           '[完整验证]('+index['ci_url']+')\n\n'
           '两个发行包直接来自上述通过检查的 CI 运行，可用 GitHub artifact attestation 核对构建来源。\n')
    (output.parent/'cli-release-notes.md').write_bytes(notes.encode('utf-8'))
    return index


def release_info(tag):
    raw=api('repos/'+manager.REPOSITORY+'/releases/tags/'+tag,missing=True)
    if raw is not None:
        return json.loads(raw)
    # Draft releases are found through the authenticated release list; the
    # tag endpoint can return 404 even when a draft already exists.
    pages=json.loads(gh('api','repos/'+manager.REPOSITORY+'/releases?per_page=100','--paginate','--slurp'))
    matches=[release for page in pages for release in page if release['tag_name']==tag]
    if len(matches)>1:
        raise ValueError('multiple release drafts identify this tag; select one before retrying')
    if not matches:
        return None
    return json.loads(api('repos/'+manager.REPOSITORY+'/releases/'+str(matches[0]['id'])))


def verify_assets(release,files,tag,complete):
    assets={asset['name']:asset for asset in release['assets']}
    if set(assets)-set(files) or (complete and set(assets)!=set(files)):
        raise ValueError('existing release contains unexpected or missing assets')
    for name,asset in assets.items():
        path=files[name]
        if asset['size']!=path.stat().st_size:
            raise ValueError('existing release asset has a different size: '+name)
        digest=asset.get('digest')
        expected='sha256:'+manager.digest_file(path)
        if digest is not None:
            if digest!=expected:
                raise ValueError('existing release asset has a different digest: '+name)
        else:
            with tempfile.TemporaryDirectory(prefix='moonground-release-verify-') as temporary:
                gh('release','download',tag,'--repo',manager.REPOSITORY,'--pattern',name,'--dir',temporary)
                if manager.digest_file(Path(temporary)/name)!=expected.split(':',1)[1]:
                    raise ValueError('downloaded release asset has a different digest: '+name)
    return set(assets)


def publish(directory,version,commit):
    checked_run(version,commit)
    index=json.loads((directory/'RELEASE_MANIFEST.json').read_text(encoding='utf-8'))
    if index['source_commit']!=commit or index['version']!=version:
        raise ValueError('prepared release identity differs')
    for target in manager.TARGETS:
        archive=directory/manager.asset_name(version,target)
        if manager.digest_file(archive)!=index['artifacts'][target]['sha256']:
            raise ValueError('prepared release archive digest differs')
        gh('attestation','verify',str(archive),'--repo',manager.REPOSITORY,
           '--signer-workflow',manager.REPOSITORY+'/.github/workflows/ci.yml',
           '--source-digest',commit,'--deny-self-hosted-runners')
    tag='v'+version
    existing=api('repos/'+manager.REPOSITORY+'/git/ref/tags/'+tag,missing=True)
    if existing is None:
        api('repos/'+manager.REPOSITORY+'/git/refs','POST',dict(ref='refs/tags/'+tag,sha=commit))
    resolved=json.loads(api('repos/'+manager.REPOSITORY+'/commits/'+tag))['sha']
    if resolved!=commit:
        raise ValueError('release tag already identifies another commit; left unchanged')
    files={item.name:item for item in directory.iterdir() if item.is_file()}
    expected={manager.asset_name(version,t) for t in manager.TARGETS}|{
        'verification-'+t+'.json' for t in manager.TARGETS}|{'SHA256SUMS','RELEASE_MANIFEST.json','moonground_cli.py'}
    if set(files)!=expected:
        raise ValueError('unexpected release files')
    sums={}
    for line in (directory/'SHA256SUMS').read_text(encoding='ascii').splitlines():
        digest,name=line.split('  ',1)
        if name in sums or name not in files or not manager.SHA256.fullmatch(digest):
            raise ValueError('invalid release checksum file')
        sums[name]=digest
    if set(sums)!=set(files)-{'SHA256SUMS'} or any(manager.digest_file(files[name])!=digest for name,digest in sums.items()):
        raise ValueError('prepared release checksum file differs from its assets')
    release=release_info(tag)
    if release is None:
        gh('release','create',tag,'--repo',manager.REPOSITORY,'--verify-tag','--draft',
           '--title','MoonGround CLI '+version,'--notes-file',str(directory.parent/'cli-release-notes.md'))
        release=release_info(tag)
    if release is None:
        raise ValueError('created release draft could not be located; retry without creating another tag')
    present=verify_assets(release,files,tag,complete=not release['draft'])
    if not release['draft']:
        return release['html_url']
    for name,path in files.items():
        if name not in present:
            gh('release','upload',tag,str(path),'--repo',manager.REPOSITORY)
    release=release_info(tag)
    verify_assets(release,files,tag,complete=True)
    api('repos/'+manager.REPOSITORY+'/releases/'+str(release['id']),'PATCH',dict(draft=False,make_latest='true'))
    release=release_info(tag)
    if release['draft']:
        raise ValueError('release is still a draft')
    verify_assets(release,files,tag,complete=True)
    return release['html_url']


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command',choices=['check-ci','prepare','publish'])
    parser.add_argument('--version',required=True)
    parser.add_argument('--commit',required=True)
    parser.add_argument('--input',type=Path)
    parser.add_argument('--output',type=Path,default=ROOT/'_build/releases')
    parser.add_argument('--run-id',type=int)
    args=parser.parse_args()
    try:
        if args.command=='check-ci':
            run=checked_run(args.version,args.commit)
            if os.environ.get('GITHUB_OUTPUT'):
                with open(os.environ['GITHUB_OUTPUT'],'a',encoding='utf-8') as stream:
                    stream.write('run_id='+str(run['databaseId'])+'\n')
            print(json.dumps(run))
        elif args.command=='prepare':
            if args.input is None or args.run_id is None:
                raise ValueError('prepare requires --input and --run-id')
            print(json.dumps(prepare(args.input,args.output,args.version,args.commit,args.run_id)))
        else:
            print(publish(args.output,args.version,args.commit))
    except (OSError,ValueError,KeyError,zipfile.BadZipFile,subprocess.SubprocessError) as error:
        parser.exit(2,str(error)+'\n')


if __name__=='__main__':
    main()
