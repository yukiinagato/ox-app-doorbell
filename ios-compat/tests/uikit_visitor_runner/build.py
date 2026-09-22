#!/usr/bin/env python3
"""Build an isolated armv7 UIKit runner from an immutable production UI freeze."""
import argparse, hashlib, json, pathlib, plistlib, shutil, subprocess
p=argparse.ArgumentParser(); p.add_argument('--source',type=pathlib.Path,required=True); p.add_argument('--out',type=pathlib.Path,required=True); p.add_argument('--case',type=int,default=0,choices=range(5)); p.add_argument('--build-number',default='9'); p.add_argument('--source-manifest',type=pathlib.Path,required=True); a=p.parse_args()
r=a.source.resolve(); out=a.out.resolve(); out.mkdir(parents=True,exist_ok=True); app=out/'DoorbellT35UIKit.app'; app.mkdir(exist_ok=True)
here=pathlib.Path(__file__).resolve().parent
core=['DBAdminAddress','DBBackdropCompositor','DBBootConfig','DBCallTiming','DBConfigUtil','DBDoorVisitorLayout','DBGeneratedStrings','DBIconAsset','DBMediaSource','DBNoticeModel','DBPairingModel','DBPurposeModel','DBSemanticStyle','DBSosSlideModel','DBTexts','DBUiTheme']
sources=[r/'ios-kiosk/src/Core'/f'{s}.m' for s in core]+[r/'ios-kiosk/src/Screens'/f'{s}.m' for s in ['DBScreen','DBDoorScreen','DBWidgets']]+[r/'ios-kiosk/src/Media/DBQrCode.m',r/'ios-kiosk/qr/qrcodegen.c',here/'main.m']
clang=subprocess.check_output(['xcrun','-f','clang'],text=True).strip(); sdk=r/'tools/sdk/iPhoneOS7.1.sdk'; base=[clang,'-arch','armv7','-miphoneos-version-min=5.1','-isysroot',str(sdk),'-Wall','-Wno-incomplete-implementation','-O1','-g']
includes=['-I'+str(r/'ios-kiosk/src'/d) for d in ['Core','Screens','Media','Net']]+['-I'+str(r/'core/include'),'-I'+str(r/'ios-kiosk/qr'),'-I'+str(r/'ios-kiosk/mini_sip')]
objects=[]; commands=[]
for source in sources:
 obj=out/(source.stem+'.o'); cmd=base+includes+(['-fobjc-arc','-fblocks'] if source.suffix=='.m' else [])+['-c',str(source),'-o',str(obj)]; commands.append(cmd); subprocess.run(cmd,check=True); objects.append(str(obj))
frameworks=sum([['-framework',f] for f in ['Foundation','UIKit','CoreGraphics','QuartzCore','Security','ImageIO','AVFoundation']],[])
cmd=base+['-o',str(app/'DoorbellT35UIKit')]+objects+frameworks; commands.append(cmd); subprocess.run(cmd,check=True)
info={'CFBundleIdentifier':'jp.ox.doorbell.t35uitest','CFBundleExecutable':'DoorbellT35UIKit','CFBundleName':'T35 UIKit','CFBundleDisplayName':'T35 UIKit','CFBundlePackageType':'APPL','CFBundleShortVersionString':'1.0.0','CFBundleVersion':a.build_number,'T35Case':a.case,'T35SourceManifest':hashlib.sha256(a.source_manifest.read_bytes()).hexdigest(),'CFBundleSupportedPlatforms':['iPhoneOS'],'CFBundleInfoDictionaryVersion':'6.0','LSRequiresIPhoneOS':True,'UIRequiredDeviceCapabilities':['armv7'],'MinimumOSVersion':'5.1','UIDeviceFamily':[2],'UIStatusBarHidden':True,'UISupportedInterfaceOrientations':['UIInterfaceOrientationPortrait','UIInterfaceOrientationLandscapeLeft','UIInterfaceOrientationLandscapeRight'],'CFBundleURLTypes':[{'CFBundleURLSchemes':['doorbell-t35-test']}]}
with (app/'Info.plist').open('wb') as f: plistlib.dump(info,f)
with (out/'entitlements.plist').open('wb') as f: plistlib.dump({'application-identifier':info['CFBundleIdentifier']},f)
subprocess.run(['ldid','-S'+str(out/'entitlements.plist'),str(app/'DoorbellT35UIKit')],check=True)
for folder in ['ios-kiosk/resources/icons','ios-kiosk/src/Resources']:
 for source in (r/folder).glob('*.png'): shutil.copy2(source,app/source.name)
sha=lambda q:hashlib.sha256(q.read_bytes()).hexdigest()
(out/'manifest.json').write_text(json.dumps({'source_root':str(r),'bundle':info,'sources':{str(s):sha(s) for s in sources},'commands':commands,'binary_sha256':sha(app/'DoorbellT35UIKit'),'excluded':'No Core library, production CoreBridge, Router, SIP, network or audio implementation is linked.'},indent=2)+'\n')
print(app)
