#!/usr/bin/env python3
"""Rebuild unchanged release lanes against the frozen r5 visitor-controller fix."""
import concurrent.futures,datetime,hashlib,json,pathlib,plistlib,subprocess
r=pathlib.Path.cwd();e=r/'verification/remediation-q01-q18/T35-ios-modern/evidence';h=lambda p:hashlib.sha256(p.read_bytes()).hexdigest();manifest=e.parent/'source-r5-final.json'
def run(name):
 prior=json.loads((e/(name+'-r4.json')).read_text());cmd=[x.replace('-r4','-r5') for x in prior['command']];meta={'command':cmd,'cwd':str(r),'source_manifest':str(manifest),'source_manifest_sha256':h(manifest),'started_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'scope':'Production r5 visitor-action identity fix, frozen T12 real-PJSIP Core, unsigned build only.'}
 with (e/(name+'-r5.log')).open('w') as log:done=subprocess.run(cmd,cwd=r,stdout=log,stderr=subprocess.STDOUT)
 meta.update(exit_code=done.returncode,finished_at=datetime.datetime.now(datetime.timezone.utc).isoformat())
 derived=r/('build/remediation-t35-ios-modern-r1-20260923/'+name+'-r5');apps=list(derived.glob('Build/Products/*/*.app'))
 if done.returncode==0:
  meta['apps']=[]
  for app in apps:
   info=plistlib.loads((app/'Info.plist').read_bytes());meta['apps'].append({'path':str(app),'bundle':info['CFBundleIdentifier'],'version':info['CFBundleShortVersionString'],'build':info['CFBundleVersion'],'files':{str(f.relative_to(app)):h(f) for f in sorted(app.rglob('*')) if f.is_file()}})
 (e/(name+'-r5.json')).write_text(json.dumps(meta,indent=2)+'\n');print(name,done.returncode,flush=True)
 return done.returncode
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:results=list(pool.map(run,['ios9-arm64','tvos']))
raise SystemExit(max(results))
