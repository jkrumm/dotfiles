#!/usr/bin/env python3
"""Extra statistics quoted in the report (idempotency proof, chaos, decision tests, episode kills,
machine restarts, lease and timer, redeploy, nominal timeline) from results/full/results.json.

Usage: extra_stats.py
"""
import json
import statistics as st
from pathlib import Path

R = json.loads((Path(__file__).resolve().parent.parent / 'results' / 'full' / 'results.json').read_text())['runs']
def sel(o,t): return [r for r in R if r['option']==o and r['test']==t]
def fl(rs): return [fm for r in rs for fm in r['flows'].values()]
def med(xs): xs=[x for x in xs if x is not None]; return round(st.median(xs),2) if xs else None
def mx(xs): xs=[x for x in xs if x is not None]; return round(max(xs),2) if xs else None
print("== idempotency")
for t in ('b','b_deploy','b_nokey'):
    for o in 'ab':
        rs=sel(o,t); f=fl(rs)
        print(t,o,'runs',len(rs),'created prs',sum(x['prs'] for x in f),'deploys',sum(x['deploys'] for x in f),'dups',sum(x['duplicates'] for x in f),'runs_with_dup',sum(x['duplicates']>0 for x in f),'replayed',sum(x['replayed_calls'] for x in f), 'ops_in_doubt@kill', [r['snapshots'].get('at_kill',{}).get('flows',{}).get(next(iter(r['flows'])),{}).get('ops_in_doubt') for r in rs])
print("== chaos")
for o in 'ab':
    rs=sel(o,'h'); f=fl(rs); k=[x for r in rs for x in r['kills']]
    print('h',o,'runs',len(rs),'pass',sum(bool(r['pass']) for r in rs),'kills',len(k),'machine',sum(x['scope']=='machine' for x in k),'dups',sum(x['duplicates'] for x in f),'missing',sum(x['missing'] for x in f),'replayed',sum(x['replayed_calls'] for x in f),'redrives',sum(e['redrive_events'] for x in f for e in x['episodes'].values()),'rec med/max',med([y for x in f for y in x['recovery_s']]),mx([y for x in f for y in x['recovery_s']]))
print("== decision tests")
for t in ('c1','c2','c3','c4','c5','c5s'):
    for o in 'ab':
        rs=sel(o,t)
        if not rs: continue
        f=fl(rs)
        print(t,o,'pass',sum(bool(r['pass']) for r in rs),'/',len(rs),'sources',sorted({(x['decided_by'],x['decision']) for x in f}),'late_s med/max',med([d['late_s'] for x in f for d in x['decision_taken'] if d['by']=='default']),mx([d['late_s'] for x in f for d in x['decision_taken'] if d['by']=='default']),'after_restart',med([x.get('decision_after_restart_s') for x in f]),mx([x.get('decision_after_restart_s') for x in f]), 'wait->kill..', )
print("== d")
for o in 'ab':
    rs=sel(o,'d')
    for kind in ('investigate','implement'):
        sub=[r for r in rs if r.get('kill_kind')==kind]
        print('d',o,kind,len(sub),'detect_s',[r.get('redrive_detect_s') for r in sub],'lost',[r['marks'].get('lost_partial_unit_s') for r in sub],'pass',[bool(r['pass']) for r in sub])
print("== e")
for o in 'ab':
    for r in sorted(sel(o,'e'),key=lambda r:r['idx']):
        fm=next(iter(r['flows'].values()))
        print('e',o,r['idx'],r['phase'],'pass',r['pass'],'rec',fm['recovery_s'],'redrive_after_kill',fm.get('redrive_after_kill_s'),'dec_after_restart',fm.get('decision_after_restart_s'),'lost',r['marks'].get('lost_partial_unit_s'),'wall',fm['wall_s'])
print("== f")
for o in 'ab':
    for r in sorted(sel(o,'f'),key=lambda r:r['idx']):
        iv=r['slot_intervals']; gap=round(iv[1]['enter']-iv[0]['exit'],2)
        late=[x for fm in r['flows'].values() for x in fm['timers']['late_s']]
        print('f',o,r['idx'],'pass',r['pass'],'viol',r['mutex_violations'],'Y.enter-X.exit',gap,'timer late',late,'early',[fm['timers']['early_calls'] for fm in r['flows'].values()])
print("== g")
for t in ('g','g_pinned','g_break'):
    for o in 'ab':
        rs=sel(o,t)
        if rs: print(t,o,'runs',len(rs),'recovered_no_rescue',sum(bool(r.get('recovered_without_rescue')) for r in rs),'rescue',sorted({r.get('rescue') for r in rs if r.get('rescue')}),'rescue_s',[r.get('rescue_completion_s') for r in rs],'status',sorted({r.get('dbos_status') for r in rs if r.get('dbos_status')}),'completed',sum(bool(r['completed']) for r in rs))
print("== happy/nominal")
for o in 'ab':
    print('happy',o,[next(iter(r['flows'].values()))['wall_s'] for r in sorted(sel(o,'happy'),key=lambda r:r['idx'])], 'startup ready_s', [r['loops'][0]['ready_s'] for r in sel(o,'happy')])
print("== overall")
for o in 'ab':
    rs=[r for r in R if r['option']==o and r['test'] not in ('b_nokey',)]
    print(o,'runs',len(rs),'passed',sum(bool(r['pass']) for r in rs),'completed',sum(bool(r['completed']) for r in rs),'dups',sum(x['duplicates'] for r in rs for x in r['flows'].values()),'missing',sum(x['missing'] for r in rs for x in r['flows'].values()),'kills approx',sum(1 for r in rs if 't_kill' in r['marks']))
