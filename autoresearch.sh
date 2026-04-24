#!/usr/bin/env bash
set -euo pipefail

python3 - <<'PY'
import os, subprocess, tempfile, time, statistics
from pathlib import Path

ROOT = Path('.').resolve()
SM = ROOT/'zig-out/release/smll'
ZTK = ROOT/'benchmarks/vendor/ztk'
RTK = ROOT/'benchmarks/vendor/rtk'

subprocess.run(['zig','build','release'], check=True, stdout=subprocess.DEVNULL)

cases = [
    ("ls -la", 'tests/fixtures/ls_la.txt', ['ls','-la']),
    ("tree src", 'tests/fixtures/tree_src.txt', ['tree','src']),
    ("find -ls", 'tests/fixtures/find_ls.txt', ['find','.','-ls']),
    ("git status", 'tests/fixtures/git_status_dirty.txt', ['git','status']),
    ("git diff", 'tests/fixtures/git_diff_simple.txt', ['git','diff']),
    ("git log", 'tests/fixtures/git_log_linear.txt', ['git','log']),
    ("git show", 'tests/fixtures/git_show_simple.txt', ['git','show']),
    ("git blame", 'tests/fixtures/git_blame_simple.txt', ['git','blame','src/main.zig']),
    ("docker ps", 'tests/fixtures/docker_ps.txt', ['docker','ps']),
    ("docker logs", 'tests/fixtures/docker_logs.txt', ['docker','logs','api']),
    ("kubectl get pods", 'tests/fixtures/kubectl_pods.txt', ['kubectl','get','pods']),
    ("cargo test", 'tests/fixtures/cargo_test_failing.txt', ['cargo','test']),
    ("pytest", 'tests/fixtures/pytest_failing.txt', ['pytest']),
    ("jest", 'tests/fixtures/jest_failing.txt', ['jest']),
    ("tsc", 'tests/fixtures/tsc_errors.txt', ['tsc']),
    ("npm install", 'tests/fixtures/npm_install.txt', ['npm','install']),
    ("go test -v", 'tests/fixtures/go_test_v.txt', ['go','test','-v']),
    ("rg --files", 'tests/fixtures/rg_files.txt', ['rg','--files']),
]

def run_capture(cmd, env):
    p = subprocess.run(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return p.returncode, p.stdout

def median_ms(cmd, env, rounds=9, warmup=2):
    for _ in range(warmup):
        subprocess.run(cmd, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    xs=[]
    for _ in range(rounds):
        t0=time.perf_counter_ns()
        subprocess.run(cmd, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        xs.append((time.perf_counter_ns()-t0)/1e6)
    return statistics.median(xs)

sizes = {'smll':SM.stat().st_size,'ztk':ZTK.stat().st_size,'rtk':RTK.stat().st_size}
rows=[]
for name, fixture, cmd in cases:
    data=(ROOT/fixture).read_bytes()
    raw=len(data)
    with tempfile.TemporaryDirectory() as td:
        shim=Path(td)/cmd[0]
        shim.write_text('#!/bin/sh\ncat <<\'EOF\'\n'+data.decode('utf-8','replace')+'\nEOF\n')
        shim.chmod(0o755)
        env=os.environ.copy(); env['PATH']=f"{td}:{env.get('PATH','')}"
        tcmd={
            'smll':[str(SM)]+cmd,
            'ztk':[str(ZTK),'run']+cmd,
            'rtk':[str(RTK)]+cmd,
        }
        r={'name':name,'raw':raw,'tools':{}}
        for t,c in tcmd.items():
            rc,out=run_capture(c,env)
            ms=median_ms(c,env)
            red=(100*(raw-len(out))/raw) if raw else 0.0
            r['tools'][t]={'rc':rc,'out':len(out),'red':red,'ms':ms,'nonempty':len(out.strip())>0}
        rows.append(r)

# Parity score vs RTK compression behavior: 1.0 if equal reduction, linearly down to 0
# at 100-point distance. This rewards closeness while preserving freedom to keep signal.
parity_points=0.0
for r in rows:
    sr=r['tools']['smll']['red']
    rr=r['tools']['rtk']['red']
    delta=abs(sr-rr)
    parity=max(0.0, 1.0 - (delta/100.0))
    # require non-empty output in both tools for parity credit
    if r['tools']['smll']['nonempty'] and r['tools']['rtk']['nonempty']:
        parity_points += parity

size_cap_ok = 1 if sizes['smll'] <= sizes['ztk'] else 0
if not size_cap_ok:
    parity_points = 0.0

avg = lambda t,k: sum(r['tools'][t][k] for r in rows)/len(rows)

print('# RTK feature-parity benchmark (size-capped)')
print(f'Cases: {len(rows)}')
print(f"size cap: smll({sizes['smll']}) <= ztk({sizes['ztk']}) => {'OK' if size_cap_ok else 'FAIL'}")
print(f'parity_points={parity_points:.3f}')

print(f"METRIC parity_points={parity_points:.3f}")
print(f"METRIC size_cap_ok={size_cap_ok}")
print(f"METRIC smll_bytes={sizes['smll']}")
print(f"METRIC ztk_bytes={sizes['ztk']}")
print(f"METRIC rtk_bytes={sizes['rtk']}")
print(f"METRIC cases={len(rows)}")
print(f"METRIC smll_avg_reduction_pct={avg('smll','red'):.3f}")
print(f"METRIC rtk_avg_reduction_pct={avg('rtk','red'):.3f}")
print(f"METRIC smll_avg_latency_ms={avg('smll','ms'):.3f}")
print(f"METRIC rtk_avg_latency_ms={avg('rtk','ms'):.3f}")
PY
