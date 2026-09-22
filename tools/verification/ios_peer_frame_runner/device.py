#!/usr/bin/env python3
"""Manage only the authorized Air 1 isolated UIKit test bundle and its generated evidence."""
import argparse,json,pathlib,subprocess
p=argparse.ArgumentParser();p.add_argument('action',choices=['install','wait','collect','restore','status']);a=p.parse_args();r=pathlib.Path.cwd();b=r/'build/remediation-t15-device-uikit';out=r/'verification/remediation-q01-q18/T15/evidence/device-uikit';host='doorbell-ipad-air1';remote='/private/var/containers/Bundle/Application/F1545678-1234-4234-8234-123456789ABC';owned='/var/mobile/Library/DoorbellT15UIKit'
def ssh(command,timeout=45):
 q=subprocess.run(['ssh','-o','ConnectTimeout=8',host,command],capture_output=True,text=True,timeout=timeout)
 with (out/'air1-device-actions.log').open('a') as f:f.write(command+'\n'+q.stdout+q.stderr+'\nexit='+str(q.returncode)+'\n')
 print(q.stdout.strip(),flush=True);q.check_returncode();return q.stdout
if a.action=='install':
 ssh('mkdir -p '+remote+'/stage '+owned+'; chown mobile:mobile '+owned+'; rm -f '+owned+'/*.json '+owned+'/*.png')
 subprocess.run(['scp','-O','-r',str(b/'xcode/Build/Products/Debug-iphoneos/DoorbellIOS9.app'),host+':'+remote+'/stage/'],check=True,timeout=90)
 subprocess.run(['scp','-O',str(b/'register'),host+':'+owned+'/register'],check=True,timeout=30)
 ssh('rm -rf '+remote+'/DoorbellIOS9.app; mv '+remote+'/stage/DoorbellIOS9.app '+remote+'/DoorbellIOS9.app; rmdir '+remote+'/stage; chmod 755 '+owned+'/register; chown -R mobile:mobile '+remote+'; '+owned+'/register register '+remote+'/DoorbellIOS9.app')
 ssh(owned+'/register inspect '+remote+'/DoorbellIOS9.app/Info.plist; /binpack/usr/local/bin/lsdtrip.arm64 launch jp.ox.doorbell.t15uitest')
elif a.action=='wait':
 ssh('for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do if [ -f '+owned+'/result.json ]; then cat '+owned+'/result.json; exit 0; fi; sleep 2; done; exit 1',40)
elif a.action=='collect':
 destination=out/'air1-results';destination.mkdir(exist_ok=True)
 ssh('ls -l '+owned)
 for pattern in ['*.json','*.png']:
  subprocess.run(['scp','-O',host+':'+owned+'/'+pattern,str(destination)],check=True,timeout=40)
elif a.action=='restore':
 ssh('/binpack/usr/local/bin/lsdtrip.arm64 launch jp.ox.doorbell')
 result=out/'air1-results/result.json'
 if result.exists():
  pid=int(json.loads(result.read_text())['pid']);ssh('kill '+str(pid)+' 2>/dev/null || true')
else:
 ssh('launchctl list | grep -E "doorbell|Doorbell"; ls -l '+owned)
