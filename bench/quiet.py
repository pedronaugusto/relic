"""Local repository, transport, inflate and regression workloads, interleaved."""
from pathlib import Path
import json
import os
import select
import shutil
import subprocess
import sys
from quiet_common import Pass, tsv

def copy_repo(p, src, dst):
    if dst.exists():shutil.rmtree(dst)
    p.run(['cp','-ac' if sys.platform=='darwin' else '-a',src,dst])

# What the comparison writers leave in the scratch directory: git's
# `gitpack-<hash>.pack`, gix's `gix.pack` and go-git's `gogit.pack`, with the
# index and reverse index `git index-pack` writes beside each.
WRITER_OUTPUTS=('gitpack-*','gix.*','gogit.*')

def reset_pack_outputs(scratch):
    """Remove every pack, and its indexes, the comparison writers left."""
    for pattern in WRITER_OUTPUTS:
        for old in scratch.glob(pattern):old.unlink()

def written_packs(repo,scratch):
    """Every pack a pack-writing point can have left."""
    packs=list((repo/'.git/objects/pack').glob('*.pack'))
    for pattern in WRITER_OUTPUTS:packs+=[p for p in scratch.glob(pattern) if p.suffix=='.pack']
    return sorted(packs)

# libgit2's packbuilder streams its pack into a byte count and keeps no file.
STREAMED_PACKS=('libgit2',)

def check_packwrite(evidence,repo,scratch,run):
    """Validate every pack a pack-writing point wrote, strictly. Only an
    unavailable operation writes nothing; a metric the tool cannot report,
    such as `deltas`, says nothing about the pack it wrote."""
    if evidence['operation']=='available' and evidence['reported_side'] in STREAMED_PACKS:
        evidence['pack_verification']='not kept: streamed to a byte count'
    elif evidence['operation']=='available':
        packs=written_packs(repo,scratch)
        if not packs:raise ValueError('pack writer produced no pack')
        for pack in packs:run(['git','index-pack','--strict',pack])
        evidence['pack_verification']='passed'
        evidence['packs_verified']=len(packs)
    return evidence

def main():
    p=Pass(__file__)
    try:
        source={s:p.snapshot(s) for s in ('before','after')}
        binary={s:p.zig(source[s]) for s in source}
        transport={s:p.zig(source[s],'bench/transport') for s in source}
        tools=p.here/'build/tools'
        env=p.env.copy();env.update(BENCH_BUILD_DIR=str(tools),PYTHON=sys.executable)
        if p.smoke:env['BENCH_SMOKE']='1';p.env['BENCH_SMOKE']='1'
        else:env.pop('BENCH_SMOKE',None);p.env.pop('BENCH_SMOKE',None)
        p.setup_run([p.here/'run.sh','build'],env=env)
        fx=tools/('fixture-smoke' if p.smoke else 'fixture-full');env['BENCH_FIXTURE']=str(fx)
        p.setup_run([p.here/'run.sh','fixture'],env=env)
        for asset in ('gix_bench','git2_bench','gogit_bench'):p.prepared.require(tools/asset)
        p.prepared.require(fx)
        scratch=p.build/'work';scratch.mkdir(exist_ok=True)
        commands={'git':[sys.executable,p.here/'src/git_bench.py'],'gix':[tools/'gix_bench'],
                  'libgit2':[tools/'git2_bench'],'go-git':[tools/'gogit_bench']}
        for workload in ('status','addall','revlist','catblobs','packwrite','indexrw'):
            repo=fx/'repo-packed'
            prep=None;extra=[]
            if workload=='addall':
                repo=scratch/'addall'
                def prep():
                    copy_repo(p,fx/'repo-packed',repo)
                    subprocess.run(['git','-C',str(repo),'update-index','--refresh','-q'],env=p.env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
                    p.run([sys.executable,p.here/'src/mutate.py',repo])
            if workload=='packwrite':
                repo=scratch/'loose'
                def prep():
                    copy_repo(p,fx/'repo-loose',repo)
                    reset_pack_outputs(scratch)
            if workload=='catblobs':extra=[fx/'blobs.txt']
            if workload=='indexrw':extra=[scratch]
            points=[(s,[binary[s]/'relic_bench',workload,repo,*extra]) for s in source]
            for tool,argv in commands.items():
                tool_extra=[scratch] if workload=='packwrite' and tool in ('git','gix','go-git') else extra
                points.append((tool,[*argv,workload,repo,*tool_extra]))
            expected_tree = []
            def checked(out):
                evidence=tsv(out)
                if workload=='addall' and evidence['operation']=='available':
                    tree=p.run(['git','-C',repo,'write-tree']).strip()
                    if expected_tree and tree!=expected_tree[0]:raise ValueError('staging produced a different tree')
                    if not expected_tree:expected_tree.append(tree)
                    evidence['tree']=tree
                if workload=='packwrite':check_packwrite(evidence,repo,scratch,p.run)
                return evidence
            p.interleave(workload,points,prepare=prep,check=checked)
        def regression_check(out):
            if 'All 5 tests passed.' not in out or out.count('test.benchmark:')!=4:raise ValueError('regression smoke skipped or failed tests')
            return {'measurement_workloads':4,'tests_total':5}
        p.interleave('regressions',[(s,[binary[s]/'relic-regression-measurements']) for s in source],check=regression_check)
        transport_pass(p,source,transport)
        p.finish()
    except Exception as error:p.save(str(error));raise

def transport_pass(p,source,binary):
    fx=p.build/'transport-fixtures';fx.mkdir(exist_ok=True)
    specs={'smoke':(1,32,1,1,1)} if p.smoke else {'small':(200,1000,100,3,20),'medium':(3000,2000,1000,10,20),'large':(20000,2000,300,20,20)}
    if p.preparing:
        for size,spec in specs.items():
            repo=fx/(size+'.git')
            if repo.exists():shutil.rmtree(repo)
            p.run(['git','init','-q','--bare',repo]);p.run(['git','-C',repo,'symbolic-ref','HEAD','refs/heads/main'])
            stream=subprocess.check_output([sys.executable,p.here/'transport/src/genrepo.py',*map(str,spec)])
            subprocess.run(['git','-C',str(repo),'fast-import','--quiet','--done'],input=stream,env=p.env,check=True,capture_output=True)
            p.run(['git','-C',repo,'repack','-adq'])
            base=fx/(size+'-base.git')
            if base.exists():shutil.rmtree(base)
            p.run(['git','clone','-q','--bare',repo,base]);p.run(['git','-C',base,'update-ref','refs/heads/main','refs/tags/base'])
            p.run(['git','-C',base,'repack','-adq']);p.run(['git','-C',base,'prune'])
            for state,origin in [('tip',repo),('base',base)]:
                client=fx/(size+'-client-'+state)
                if client.exists():shutil.rmtree(client)
                p.run(['git','clone','-q','--no-checkout',origin,client])
    p.prepared.require(fx)
    if p.plan_only:return
    env=p.env.copy();env['GIT_SSH_COMMAND']=str(p.here/'transport/src/ssh-standin.sh')
    server=subprocess.Popen([sys.executable,p.here/'transport/src/httpgit.py',str(fx)],env=env,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True)
    try:
        if not select.select([server.stdout],[],[],15)[0]:raise RuntimeError('HTTP fixture server did not start')
        port=int(server.stdout.readline())
        dst=p.build/'transport-dst'
        expected={size:p.run(['git','-C',fx/(size+'.git'),'rev-parse','HEAD']).strip() for size in specs}
        for size in specs:
            packs=sorted((fx/(size+'.git')/'objects/pack').glob('*.pack'))
            if len(packs)!=1:raise ValueError('expected one pack')
            p.interleave('inflate/'+size,[(s,[binary[s]/'inflate-bench',packs[0],1 if p.smoke else 3]) for s in source])
            for kind in ('http','ssh'):
                url=f'http://127.0.0.1:{port}/{size}.git' if kind=='http' else 'ssh://bench.invalid'+str(fx/(size+'.git'))
                for workload in ('clone','clone-fsck','fetch-noop','fetch-new'):
                    def prep():
                        if dst.exists():shutil.rmtree(dst)
                        if workload.startswith('fetch'):
                            copy_repo(p,fx/(size+'-client-'+('tip' if workload=='fetch-noop' else 'base')),dst)
                            p.run(['git','-C',dst,'config','remote.origin.url',url])
                    points=[]
                    for side in source:
                        argv=[binary[side]/'relic_transport_bench']
                        argv+=['clone',url,dst] if workload.startswith('clone') else ['fetch',dst]
                        if workload=='clone-fsck':argv+=['check']
                        points.append((side,argv))
                    git=['git']
                    if workload=='clone-fsck':git+=['-c','transfer.fsckObjects=true']
                    git+=['clone','-q','--bare',url,dst] if workload.startswith('clone') else ['-C',dst,'fetch','-q','origin']
                    # Git wall time includes command startup; library values exclude it.
                    points.append(('git',[sys.executable,p.here/'transport/src/git_wall.py',*map(str,git)]))
                    def check(out):
                        actual=p.run(['git','-C',dst,'rev-parse','HEAD' if workload.startswith('clone') else 'refs/remotes/origin/main']).strip()
                        if actual!=expected[size]:raise ValueError('transport produced wrong tip')
                        p.run(['git','-C',dst,'fsck','--strict','--no-dangling'])
                        return {'tip':actual,'fsck':'passed'}
                    p.interleave(f'{kind}/{size}/{workload}',points,prepare=prep,env=env,check=check)
    finally:
        server.terminate()
        try:server.wait(timeout=5)
        except subprocess.TimeoutExpired:server.kill();server.wait()

if __name__=='__main__':main()
