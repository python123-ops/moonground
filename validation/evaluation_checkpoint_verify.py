#!/usr/bin/env python3
"""Compare complete and resumed evaluations with independent Decimal reductions."""
import argparse
import copy
from decimal import localcontext
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import tempfile

import measurement_evaluation_verify as reference
from measurement_acceptance_verify import check_requirements
from public_reports import portable_report

ROOT=Path(__file__).resolve().parent.parent


def encode(value):
    return json.dumps(value,separators=(',',':'),allow_nan=False)


def run(binary,source,rows,accept=False,expected=None,ending='\n',final=True):
    payload=ending.join([source if isinstance(source,str) else encode(source)]+[encode(row) for row in rows])+(ending if final else '')
    mode='--accept-measurements-checkpoint' if accept else '--evaluate-measurements-checkpoint'
    result=subprocess.run([str(binary),mode],input=payload.encode(),stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=120)
    if expected==2:
        assert result.returncode==2 and not result.stdout and result.stderr,(result.returncode,result.stdout,result.stderr)
        return None
    assert result.returncode in (0,3) and not result.stderr,(result.returncode,result.stderr)
    assert len(result.stdout.splitlines())==1
    value=json.loads(result.stdout)
    assert set(value)=={'report','resume'}
    assert result.returncode==(3 if accept and not value['report']['accepted'] else 0)
    if expected is not None:assert result.returncode==expected
    return value


def numerical(binary):
    cases=[]
    statistics=dict(scalars=0,exact_fields=0,maximum_tolerance_fraction=0,
                    maximum_absolute_error_by_unit=dict(m=0,mps=0,dimensionless=0))
    checks=0
    max_checkpoint_bytes=0
    with localcontext() as context:
        context.prec=160
        for name,rows in reference.fixtures():
            expected,scales=reference.offline_report(rows)
            baseline=run(binary,dict(session_id='evaluation'),rows)
            reference.compare(baseline['report'],expected,scales,statistics)
            assert baseline['report']==reference.native(binary,rows)
            for cut in sorted({0,min(1,len(rows)),len(rows)//2,len(rows)}):
                prefix=run(binary,dict(session_id='evaluation'),rows[:cut])
                saved=encode(prefix['resume'])
                max_checkpoint_bytes=max(max_checkpoint_bytes,len(saved.encode('utf-8')))
                assert max_checkpoint_bytes<=16384
                continued=run(binary,dict(resume=prefix['resume']),rows[cut:],ending='\r\n',final=False)
                assert continued==baseline,(name,cut)
                assert encode(prefix['resume'])==saved
                requirements=dict(position_m=dict(min_samples=1,min_coverage=0.75,max_error=1e308),
                                  speed_mps=dict(min_samples=1,min_coverage=0.75,max_rmse=1e308))
                acceptance=run(binary,dict(resume=prefix['resume'],requirements=requirements),rows[cut:],accept=True)
                assert acceptance['report']['evaluation']==baseline['report']
                checks+=check_requirements(baseline['report'],requirements,acceptance['report'])
                cases.append(dict(name=name,cut=cut,frames=len(rows),passed=True))
    return cases,statistics,checks,max_checkpoint_bytes


def protocol(binary):
    cases=[]
    prefix=run(binary,dict(session_id='evaluation'),[reference.paired(0,[reference.track(1,0)],[reference.reference(1)])])
    base=prefix['resume']
    def bad(name,value):
        run(binary,dict(resume=value),[],expected=2)
        cases.append(dict(name=name,passed=True))
    for key,value in [('version',2),('session_id',''),('max_tracks',0),('max_tracks',4097),('max_samples',0),
                      ('first_timestamp_us',None),('last_timestamp_us','-1'),('first_timestamp_us',1),
                      ('position_bias_m',[1e308,0]),('speed_bias_mps',1e308),('extra',0)]:
        cp=copy.deepcopy(base);cp[key]=value;bad('invalid-'+key+'-'+str(value),cp)
    for key,value in [('references',2),('speed_references',2),('measurements',0),('without_reference',1),
                      ('ready',0),('missing',1),('initializing',-1),('frames','0'),('frames',1)]:
        cp=copy.deepcopy(base);cp['counts'][key]=value;bad('invalid-count-'+key+'-'+str(value),cp)
    for key,value in [('samples',0),('scale',-1),('maximum',1),('scaled_squares',0),('scaled_squares',2),
                      ('mean_absolute',6)]:
        cp=copy.deepcopy(base);cp['position'][key]=value;bad('invalid-accumulator-'+key+'-'+str(value),cp)
    for key in list(base):
        cp=copy.deepcopy(base);del cp[key];bad('missing-'+key,cp)
    for extra in [dict(session_id='evaluation'),dict(max_tracks=4096),dict(max_samples=10000000)]:
        run(binary,dict(resume=base,**extra),[],expected=2)
        cases.append(dict(name='resume-cannot-override-'+next(iter(extra)),passed=True))
    raw=encode(dict(resume=base))
    for name,malformed in [('duplicate',raw.replace('"version":1','"version":1,"version":1',1)),
                            ('underflow',raw.replace('"mean_absolute":5','"mean_absolute":1e-9999',1)),
                            ('rounded-fraction',raw.replace('"references":1','"references":1.00000000000000000001',1)),
                            ('overflow',raw.replace('"maximum":5','"maximum":1e9999',1))]:
        assert malformed!=raw,name
        run(binary,malformed,[],expected=2)
        cases.append(dict(name='raw-'+name,passed=True))
    run(binary,dict(resume=base),[reference.paired(0,[],[])],expected=2)
    run(binary,dict(resume=base),[reference.paired(1,[],[]),reference.paired(1,[],[])],expected=2)
    cases.append(dict(name='overlap-and-late-duplicate-have-no-summary-or-checkpoint',passed=True))
    return cases


def file_cases(binary):
    cases=[]
    with tempfile.TemporaryDirectory(prefix='moonground-evaluation-resume-') as temporary:
        directory=Path(temporary)
        measured,truth,first,last,limits=[directory/name for name in ['measured.ndjson','reference.ndjson','first.json','last.json','limits.json']]
        rows=[reference.paired(i,[reference.track(1,i)],[reference.reference(1)]) for i in range(6)]
        def files(selected):
            measured.write_bytes(('\r\n'.join(encode(row['measurement']) for row in selected)+('\r\n' if selected else '')).encode())
            truth.write_bytes(('\n'.join(encode(row['reference']) for row in selected)+('\n' if selected else '')).encode())
        command=[sys.executable,str(ROOT/'examples/evaluate_measurements.py'),'--binary',str(binary),
                 '--measurements',str(measured),'--references',str(truth)]
        def execute(options,expected=0):
            result=subprocess.run(command+options,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=120)
            assert result.returncode==expected,(result.returncode,result.stderr)
            assert b'Traceback (most recent call last)' not in result.stderr
        files(rows[:3])
        limits.write_text('{"position_m":{"min_samples":6,"min_coverage":1,"max_error":5}}')
        execute(['--checkpoint','--max-samples','10','--requirements',str(limits),'--output',str(first)],3)
        saved=first.read_bytes()
        prefix=json.loads(saved)
        assert prefix['resume']['counts']['frames']=='3' and prefix['resume']['max_samples']==10
        assert prefix['acceptance']['accepted'] is False
        cases.append(dict(name='file-report-contains-complete-state-and-custom-capacities',passed=True))
        cases.append(dict(name='failed-acceptance-report-still-contains-valid-continuation-state',passed=True))
        files(rows[3:])
        execute(['--resume',str(first),'--requirements',str(limits),'--output',str(last)])
        continued=json.loads(last.read_text())
        assert continued['acceptance']['accepted'] and continued['evaluation']==reference.native(binary,rows)
        assert continued['inputs']['resume_sha256']==hashlib.sha256(saved).hexdigest()
        assert continued['configuration']['max_samples']==10 and continued['alignment_scope']=='current_inputs'
        assert continued['alignment']['paired_frames']==3 and continued['evaluation']['counts']['frames']=='6'
        assert first.read_bytes()==saved
        cases.append(dict(name='next-log-chunk-restores-capacities-and-cumulative-metrics',passed=True))
        preserved=last.read_bytes()
        for options in [['--max-samples','9'],['--session-id','other']]:
            execute(['--resume',str(first),'--output',str(last)]+options,2)
            assert last.read_bytes()==preserved
        cases.append(dict(name='resume-cannot-change-session-or-capacity',passed=True))
        execute(['--resume',str(first),'--output',str(first)],2)
        assert first.read_bytes()==saved
        cases.append(dict(name='resume-input-cannot-be-replaced-by-the-new-report',passed=True))
        files(rows[:1])
        execute(['--resume',str(first),'--output',str(last)],2)
        assert last.read_bytes()==preserved
        cases.append(dict(name='overlapping-log-chunk-preserves-both-existing-reports',passed=True))
        files([])
        execute(['--resume',str(first),'--output',str(last)])
        assert json.loads(last.read_text())['evaluation']['counts']['frames']=='3'
        cases.append(dict(name='empty-continuation-keeps-the-original-population',passed=True))
        bad=directory/'bad.json'
        for name,raw in [('summary-only',encode(dict(evaluation=prefix['evaluation']))),
                         ('duplicate',encode(prefix).replace('"version":1','"version":1,"version":1',1)),
                         ('underflow',encode(prefix).replace('"mean_absolute":5','"mean_absolute":1e-9999',1)),
                         ('too-large',' '*1048577)]:
            bad.write_bytes(raw.encode())
            previous=last.read_bytes()
            execute(['--resume',str(bad),'--output',str(last)],2)
            assert last.read_bytes()==previous
            cases.append(dict(name='file-rejects-'+name+'-without-replacing-report',passed=True))
        sys.path.insert(0,str(ROOT/'tools'))
        import moonground_cli as manager
        import package_cli as packager
        from cli_jobs_verify import fixture,records,jobs
        bundle=packager.create_bundle(binary,directory/'bundle',packager.module_version(),'0'*40,True)
        installation=directory/'install'
        manager.install_archive(installation,directory/'bundle'/bundle['archive'],bundle['sha256'])
        manager_command=[sys.executable,str(ROOT/'tools/moonground_cli.py'),'--prefix',str(installation),'evaluate']
        installed_first,installed_last=directory/'installed-first.json',directory/'installed-last.json'
        options=['--measurements',str(measured),'--references',str(truth)]
        files(rows[:3])
        assert subprocess.run(manager_command+options+['--checkpoint','--max-samples','10','--output',str(installed_first)],
                              stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=120).returncode==0
        files(rows[3:])
        process=subprocess.run(manager_command+options+['--resume',str(installed_first),'--requirements',str(limits),'--output',str(installed_last)],
                               stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=120)
        assert process.returncode==0,process.stderr
        assert json.loads(installed_last.read_text())['evaluation']==continued['evaluation']
        cases.append(dict(name='installed-evaluate-checkpoint-and-resume-use-the-native-state',passed=True))
        state_input,state,state_reference=[directory/name for name in ['state-input.ndjson','state.sqlite','state-reference.ndjson']]
        state_input.write_bytes(records(fixture(frames=6,targets=1)))
        jobs.replay(binary,state_input,state)
        state_reference.write_bytes(records([dict(timestamp_us=str(i*200000),samples=[
            dict(track_id=1,position_m=[1+i*0.01,0])]) for i in range(6)]))
        state_options=['--state',str(state),'--references',str(state_reference),'--output',str(installed_last)]
        process=subprocess.run(manager_command+state_options+['--checkpoint'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=120)
        assert process.returncode==0,process.stderr
        state_report=json.loads(installed_last.read_text())
        assert state_report['resume']['counts']['frames']=='6' and state_report['measurement_source']['complete']
        before=installed_last.read_bytes()
        process=subprocess.run(manager_command+state_options+['--resume',str(installed_first)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=120)
        assert process.returncode==2 and installed_last.read_bytes()==before
        cases.append(dict(name='database-snapshot-can-export-a-checkpoint-but-cannot-be-reprocessed-as-a-later-chunk',passed=True))
        assert not list((installation/'versions').rglob('__pycache__'))
        manager.status(installation)
        cases.append(dict(name='checkpoint-helper-loading-preserves-immutable-version-slots',passed=True))
    return cases


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary',type=Path,required=True)
    parser.add_argument('--web',action='store_true')
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    binary=args.binary.resolve()
    cases,statistics,checks,max_checkpoint_bytes=numerical(binary)
    result=dict(status='passed',data_scope='synthetic_metric_references',numerical_cases=cases,statistics=statistics,checks=checks,
                max_checkpoint_bytes=max_checkpoint_bytes,
                protocol_cases=protocol(binary),file_adapter_cases=file_cases(binary),
                binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                source_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                reference_sha256=hashlib.sha256((ROOT/'validation/measurement_evaluation_verify.py').read_bytes()).hexdigest(),
                acceptance_reference_sha256=hashlib.sha256((ROOT/'validation/measurement_acceptance_verify.py').read_bytes()).hexdigest(),
                adapter_sha256=hashlib.sha256((ROOT/'examples/evaluate_measurements.py').read_bytes()).hexdigest(),
                manager_sha256=hashlib.sha256((ROOT/'tools/moonground_cli.py').read_bytes()).hexdigest(),
                runner_sha256=hashlib.sha256((ROOT/'tools/moonground_jobs.py').read_bytes()).hexdigest(),
                support_sha256=hashlib.sha256((ROOT/'validation/cli_jobs_verify.py').read_bytes()).hexdigest(),
                python=platform.python_version(),decimal_precision=160,seed=reference.SEED,
                command='python '+' '.join(sys.argv))
    if args.web:
        process=subprocess.run(['node','--test','--test-reporter=tap','web/evaluation-checkpoint.test.mjs'],
            cwd=str(ROOT),env=dict(os.environ,MOONGROUND_CLI=str(binary)),stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=120)
        assert process.returncode==0,process.stdout.decode('utf-8','replace')
        output=process.stdout.decode()
        summary={key:int(re.search(r'^# '+key+r' (\d+)$',output,re.M)[1]) for key in ['tests','pass','fail']}
        result['web_interchange']=dict(status='passed',summary=summary,
            source_sha256=hashlib.sha256((ROOT/'web/evaluation-checkpoint.test.mjs').read_bytes()).hexdigest())
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(portable_report(result),indent=2)+'\n',encoding='utf-8')
    print(json.dumps(dict(status='passed',numerical_cases=len(cases),checks=checks,protocol_cases=len(result['protocol_cases']),file_cases=len(result['file_adapter_cases']))))


if __name__=='__main__':
    main()
