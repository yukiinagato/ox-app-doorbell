#!/usr/bin/env python3
"""Install or inspect only the isolated iPad 1 UIKit runner; never back up the device."""
import argparse, os, pathlib, re, subprocess
p=argparse.ArgumentParser(); p.add_argument('action',choices=['install','status','collect','restore','direct','diagnose','stop','crashes','wait']); p.add_argument('--bundle',type=pathlib.Path); p.add_argument('--out',type=pathlib.Path,required=True); a=p.parse_args(); a.out.mkdir(parents=True,exist_ok=True)
runbook=pathlib.Path('/Users/ox/.claude/projects/-Users-ox-Documents-project-app-doorbell/memory/project-ipad1-ui-verification.md').read_text(); env=os.environ.copy(); env['SSHPASS']=re.search(r'root/(\w+)',runbook).group(1)
options=['-o','ConnectTimeout=8','-o','StrictHostKeyChecking=yes','-o','HostKeyAlgorithms=+ssh-rsa','-o','KexAlgorithms=+diffie-hellman-group1-sha1,diffie-hellman-group14-sha1','-o','Ciphers=+aes128-cbc,3des-cbc','-o','PubkeyAuthentication=no']; host='root@10.10.38.147'
def ssh(command):
 result=subprocess.run(['sshpass','-e','ssh']+options+[host,command],env=env,text=True,capture_output=True,timeout=40)
 with (a.out/'device-actions.log').open('a') as log: log.write(command+'\n'+result.stdout+result.stderr+'\nexit='+str(result.returncode)+'\n')
 print(result.stdout.strip()); result.check_returncode(); return result.stdout
if a.action=='install':
 if a.bundle.name!='DoorbellT35UIKit.app': raise SystemExit('Unexpected bundle name')
 ssh('/bin/mkdir -p /var/mobile/Library/DoorbellT35UIKit; chown mobile:mobile /var/mobile/Library/DoorbellT35UIKit; /bin/rm -f /var/mobile/Library/DoorbellT35UIKit/*.json /var/mobile/Library/DoorbellT35UIKit/*.png /var/mobile/Library/DoorbellT35UIKit/runner.log')
 ssh('for pid in $(/bin/launchctl list | /bin/grep "UIKitApplication:jp.ox.doorbell.t35uitest" | /bin/sed "s/[[:space:]].*//"); do case "$pid" in [0-9]*) kill -9 "$pid";; esac; done; /bin/mkdir -p /Applications/DoorbellT35UIKit.stage')
 subprocess.run(['sshpass','-e','scp','-O','-r']+options+[str(a.bundle),host+':/Applications/DoorbellT35UIKit.stage/'],env=env,check=True,timeout=60)
 ssh('/bin/rm -rf /Applications/DoorbellT35UIKit.app; /bin/mv /Applications/DoorbellT35UIKit.stage/DoorbellT35UIKit.app /Applications/DoorbellT35UIKit.app; /bin/rmdir /Applications/DoorbellT35UIKit.stage')
 ssh('chown -R mobile:mobile /Applications/DoorbellT35UIKit.app; /bin/chmod 755 /Applications/DoorbellT35UIKit.app/DoorbellT35UIKit; su mobile -c /usr/bin/uicache')
 ssh('if [ -S /var/run/doorbell-keepalive.sock ]; then /usr/local/libexec/doorbell-keepalive --control begin --seconds 180 --socket /var/run/doorbell-keepalive.sock; fi; su mobile -c "/usr/bin/uiopen doorbell-t35-test://"; /bin/launchctl list | /bin/grep t35 || true')
elif a.action=='stop':
 ssh('for pid in $(/bin/launchctl list | /bin/grep "UIKitApplication:jp.ox.doorbell.t35uitest" | /bin/sed "s/[[:space:]].*//"); do case "$pid" in [0-9]*) kill -9 "$pid";; esac; done; killall DoorbellT35UIKi 2>/dev/null || true')
elif a.action=='crashes':
 ssh('/bin/ls -lt /var/mobile/Library/Logs/CrashReporter/DoorbellT35* 2>/dev/null; /bin/cat /Applications/DoorbellT35UIKit.app/Info.plist; /bin/launchctl list | /bin/grep -E "doorbell|t35"')
elif a.action=='direct':
 ssh("""chown mobile:mobile /var/mobile/Library/DoorbellT35UIKit; su mobile -c 'trap "" HUP; /Applications/DoorbellT35UIKit.app/DoorbellT35UIKit > /var/mobile/Library/DoorbellT35UIKit/launch.log 2>&1 &'""")
elif a.action=='diagnose':
 ssh('killall -0 DoorbellT35UIKit; /bin/ls -l /Applications/DoorbellT35UIKit.app /var/mobile/Library/DoorbellT35UIKit; /usr/bin/uiopen --help; /bin/cat /var/mobile/Library/DoorbellT35UIKit/launch.log')
elif a.action=='status':
 ssh('/bin/launchctl list | /bin/grep -E "doorbell|t35"; /bin/ls -l /var/mobile/Library/DoorbellT35UIKit; /bin/cat /var/mobile/Library/DoorbellT35UIKit/result.json /var/mobile/Library/DoorbellT35UIKit/launch.log')
elif a.action=='wait':
 ssh('for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do if [ -f /var/mobile/Library/DoorbellT35UIKit/result.json ]; then /bin/cat /var/mobile/Library/DoorbellT35UIKit/result.json; exit 0; fi; sleep 2; done; exit 1')
elif a.action=='collect':
 subprocess.run(['sshpass','-e','scp','-O','-r']+options+[host+':/var/mobile/Library/DoorbellT35UIKit',str(a.out)],env=env,check=True,timeout=60)
else:
 ssh('su mobile -c "/usr/bin/uiopen doorbell://"; if [ -S /var/run/doorbell-keepalive.sock ]; then /usr/local/libexec/doorbell-keepalive --control end --socket /var/run/doorbell-keepalive.sock; fi; /bin/launchctl list | /bin/grep -E "doorbell|t35"')
