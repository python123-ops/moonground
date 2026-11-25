#!/usr/bin/env python3
"""Install the Linux release in a clean Ubuntu 22.04 container and replay stdin."""

import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT=Path(__file__).resolve().parent.parent
sys.path.insert(0,str(ROOT/'tools'))
import moonground_cli as manager


def run(command,**kwargs):
    result=subprocess.run(command,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=600,**kwargs)
    if result.returncode:
        raise ValueError(result.stdout.decode('utf-8','replace')[-6000:])
    return result.stdout


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive',type=Path,required=True)
    parser.add_argument('--binary',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    if manager.host_target()!='linux-x86_64':
        parser.error('clean runtime smoke runs on Linux x86-64')
    fixture=(ROOT/'examples/warehouse.ndjson').read_bytes()
    expected=run([str(args.binary.resolve()),'--stream'],input=fixture)
    expected_rows=[json.loads(line) for line in expected.splitlines()]
    archive_sha=manager.digest_file(args.archive)
    run(['docker','pull','ubuntu:22.04'])
    image=run(['docker','image','inspect','ubuntu:22.04','--format','{{.Id}}']).decode().strip()
    with tempfile.TemporaryDirectory(prefix='cli-runtime-',dir=str(ROOT/'_build')) as temporary:
        directory=Path(temporary)
        shutil.copy2(args.archive,directory/'release.zip')
        shutil.copy2(ROOT/'tools/moonground_cli.py',directory/'moonground_cli.py')
        (directory/'warehouse.ndjson').write_bytes(fixture)
        (directory/'expected.json').write_bytes(json.dumps(expected_rows).encode('utf-8'))
        (directory/'empty-reference.ndjson').write_bytes(b'')
        for name in ['measurement-evaluation-measurements.ndjson','measurement-evaluation-reference.ndjson','measurement-acceptance-requirements.json']:
            shutil.copyfile(ROOT/'examples'/name,directory/name)
        script='''#!/bin/sh
set -eu
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends python3 libssl3 >/dev/null
for tool in moon moonc gcc clang cc node; do
  if command -v "$tool" >/dev/null 2>&1; then
    echo "unexpected build tool in clean runtime: $tool" >&2
    exit 1
  fi
done
python3 /input/moonground_cli.py --prefix /tmp/moonground install --archive /input/release.zip --sha256 "$CLI_SHA256" >/tmp/install.json
python3 /input/moonground_cli.py --prefix /tmp/moonground run -- --version-json >/tmp/version.json
python3 /input/moonground_cli.py --prefix /tmp/moonground run -- --stream </input/warehouse.ndjson >/tmp/output.ndjson
python3 /input/moonground_cli.py --prefix /tmp/moonground replay --input /input/warehouse.ndjson --state /tmp/measurements.sqlite --batch-frames 3 >/tmp/job.json
python3 /input/moonground_cli.py --prefix /tmp/moonground job-verify --state /tmp/measurements.sqlite >/tmp/verified.json
python3 /input/moonground_cli.py --prefix /tmp/moonground job-backup --state /tmp/measurements.sqlite --output /tmp/backup.sqlite >/tmp/backup.json
backup_sha=$(python3 -c 'import json;print(json.load(open("/tmp/backup.json"))["sha256"])')
python3 /input/moonground_cli.py --prefix /tmp/moonground job-restore --backup /tmp/backup.sqlite --sha256 "$backup_sha" --state /tmp/restored.sqlite >/tmp/restored.json
python3 /input/moonground_cli.py --prefix /tmp/moonground replay --input /input/warehouse.ndjson --state /tmp/restored.sqlite >/tmp/resumed.json
python3 /input/moonground_cli.py --prefix /tmp/moonground job-export --state /tmp/restored.sqlite --output /tmp/restored.ndjson >/tmp/restored-export.json
python3 /input/moonground_cli.py --prefix /tmp/moonground evaluate --measurements /input/measurement-evaluation-measurements.ndjson --references /input/measurement-evaluation-reference.ndjson --requirements /input/measurement-acceptance-requirements.json --output /tmp/acceptance.json
python3 /input/moonground_cli.py --prefix /tmp/moonground job-export --state /tmp/measurements.sqlite --output /tmp/replayed.ndjson >/tmp/export.json
python3 /input/moonground_cli.py --prefix /tmp/moonground evaluate --state /tmp/measurements.sqlite --references /input/empty-reference.ndjson --checkpoint --output /tmp/state-evaluation.json
python3 /input/moonground_cli.py --prefix /tmp/moonground evaluate --measurements /tmp/replayed.ndjson --references /input/empty-reference.ndjson --output /tmp/log-evaluation.json
python3 /input/moonground_cli.py --prefix /tmp/moonground evaluate --measurements /input/empty-reference.ndjson --references /input/empty-reference.ndjson --resume /tmp/state-evaluation.json --output /tmp/continued-evaluation.json
python3 /input/moonground_cli.py --prefix /tmp/moonground replay --input /input/warehouse.ndjson --state /tmp/incremental.sqlite --max-frames 3 >/tmp/partial-job.json
python3 /input/moonground_cli.py --prefix /tmp/moonground evaluate --state /tmp/incremental.sqlite --allow-partial --committed-only --references /input/empty-reference.ndjson --evaluation-state /tmp/evaluations.sqlite --output /tmp/incremental-first.json
python3 /input/moonground_cli.py --prefix /tmp/moonground replay --input /input/warehouse.ndjson --state /tmp/incremental.sqlite >/dev/null
python3 /input/moonground_cli.py --prefix /tmp/moonground evaluate --state /tmp/incremental.sqlite --committed-only --references /input/empty-reference.ndjson --evaluation-state /tmp/evaluations.sqlite --output /tmp/incremental-final.json
python3 /input/moonground_cli.py --prefix /tmp/moonground evaluation-status --evaluation-state /tmp/evaluations.sqlite >/tmp/evaluation-status.json
python3 /input/moonground_cli.py --prefix /tmp/moonground evaluation-export --evaluation-state /tmp/evaluations.sqlite --sequence 1 --output /tmp/exported-first.json >/dev/null
report_sha=$(python3 -c 'import json;print(json.load(open("/tmp/evaluation-status.json"))["latest_sha256"])')
python3 /input/moonground_cli.py --prefix /tmp/moonground evaluation-backup --evaluation-state /tmp/evaluations.sqlite --expected-report-sha256 "$report_sha" --output /tmp/evaluation-backup.sqlite >/tmp/evaluation-backup.json
evaluation_sha=$(python3 -c 'import json;print(json.load(open("/tmp/evaluation-backup.json"))["sha256"])')
python3 /input/moonground_cli.py --prefix /tmp/moonground evaluation-restore --evaluation-state /tmp/restored-evaluations.sqlite --backup /tmp/evaluation-backup.sqlite --sha256 "$evaluation_sha" >/dev/null
python3 /input/moonground_cli.py --prefix /tmp/moonground evaluate --state /tmp/incremental.sqlite --committed-only --references /input/empty-reference.ndjson --evaluation-state /tmp/restored-evaluations.sqlite --output /tmp/restored-evaluation.json
python3 /input/moonground_cli.py --prefix /tmp/moonground evaluation-export --evaluation-state /tmp/restored-evaluations.sqlite --sequence 1 --output /tmp/restored-first.json >/dev/null
python3 /input/moonground_cli.py --prefix /tmp/moonground evaluation-status --evaluation-state /tmp/restored-evaluations.sqlite >/tmp/restored-evaluation-status.json
python3 /input/moonground_cli.py --prefix /tmp/moonground status >/dev/null
python3 - <<'PY'
import json,sqlite3
with open('/input/expected.json') as stream: expected=json.load(stream)
with open('/tmp/output.ndjson') as stream: actual=[json.loads(line) for line in stream]
assert actual==expected
with open('/tmp/replayed.ndjson') as stream: replayed=[json.loads(line) for line in stream]
with open('/tmp/job.json') as stream: job=json.load(stream)
assert replayed==expected and job['complete'] and job['frames']==len(expected)
with open('/tmp/restored.ndjson') as stream: recovered=[json.loads(line) for line in stream]
with open('/tmp/verified.json') as stream: verified=json.load(stream)
with open('/tmp/resumed.json') as stream: resumed=json.load(stream)
assert recovered==expected and verified['integrity']=='ok' and resumed['complete'] and resumed['commits']==job['commits']
with open('/tmp/acceptance.json') as stream: acceptance=json.load(stream)
assert acceptance['acceptance']['accepted'] and acceptance['evaluation']['position_error_m']['samples']==3
with open('/tmp/state-evaluation.json') as stream: state_evaluation=json.load(stream)
with open('/tmp/log-evaluation.json') as stream: log_evaluation=json.load(stream)
assert state_evaluation['evaluation']==log_evaluation['evaluation']
assert state_evaluation['inputs']==log_evaluation['inputs'] and state_evaluation['measurement_source']['frames']==job['frames']
with open('/tmp/continued-evaluation.json') as stream: continued=json.load(stream)
assert continued['evaluation']==state_evaluation['evaluation'] and continued['resume']==state_evaluation['resume']
with open('/tmp/incremental-first.json') as stream: incremental_first=json.load(stream)
with open('/tmp/incremental-final.json') as stream: incremental_final=json.load(stream)
assert incremental_first['measurement_source']['frames']==3
assert incremental_final['evaluation']==state_evaluation['evaluation'] and incremental_final['resume']==state_evaluation['resume']
assert incremental_final['measurement_source']['evaluated_frames']==job['frames']-3
assert incremental_final['reference_cursor']['prefix_records']=='0'
with open('/tmp/evaluation-status.json') as stream: evaluation_status=json.load(stream)
assert evaluation_status['records']=='2' and evaluation_status['latest_frames']==str(job['frames'])
assert open('/tmp/exported-first.json','rb').read()==open('/tmp/incremental-first.json','rb').read()
with open('/tmp/restored-evaluation.json') as stream: restored_evaluation=json.load(stream)
with open('/tmp/restored-evaluation-status.json') as stream: restored_evaluation_status=json.load(stream)
assert restored_evaluation['resume']==incremental_final['resume'] and restored_evaluation['measurement_source']['evaluated_frames']==0
assert restored_evaluation_status['records']=='3'
assert open('/tmp/restored-first.json','rb').read()==open('/tmp/incremental-first.json','rb').read()
with open('/tmp/version.json') as stream: version=json.load(stream)
with open('/tmp/install.json') as stream: installed=json.load(stream)
assert version['version']==installed['version']
print('MOONGROUND_RUNTIME_RESULT='+json.dumps(dict(status='passed',frames=len(actual),version=version['version'],replay_frames=job['frames'],restored_frames=len(recovered),acceptance_passed=acceptance['acceptance']['accepted'],sqlite_evaluation_passed=True,evaluation_checkpoint_passed=True,state_continuation_passed=True,evaluation_state_passed=True,evaluation_backup_passed=True,sqlite_version=sqlite3.sqlite_version)))
PY
'''
        (directory/'smoke.sh').write_bytes(script.encode('utf-8'))
        output=run(['docker','run','--rm','--env','CLI_SHA256='+archive_sha,
                    '--volume',str(directory.resolve())+':/input:ro',image,'/bin/sh','/input/smoke.sh'])
    line=next(line for line in output.decode('utf-8').splitlines() if line.startswith('MOONGROUND_RUNTIME_RESULT='))
    result=json.loads(line.split('=',1)[1])
    result.update(image=image,image_label='ubuntu:22.04',archive_sha256=archive_sha,
                  installed_runtime_packages=['python3','libssl3'],build_tools_present=False)
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_bytes((json.dumps(result,indent=2)+'\n').encode('utf-8'))
    print(json.dumps(result))


if __name__=='__main__':
    main()
