#!/usr/bin/env python3
"""Build and sign only the independent physical UIKit verification app."""
import datetime,hashlib,json,pathlib,plistlib,subprocess,sys
lane=sys.argv[1];assert lane in ['baseline','candidate']
r=pathlib.Path.cwd();b=r/('build/remediation-t35-modern-device-'+lane);e=r/'verification/remediation-q01-q18/T35-ios-modern/evidence/device-uikit';h=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
flags='DEBUG IOS9_COMPAT'+(' T35_BASELINE' if lane=='baseline' else '')
cmd=['xcodebuild','-project',str(b/'source/ios/Doorbell.xcodeproj'),'-scheme','DoorbellIOS9','-configuration','Debug','-sdk','iphoneos','-destination','generic/platform=iOS','-derivedDataPath',str(b/'xcode'),'ARCHS=arm64','ONLY_ACTIVE_ARCH=YES','CODE_SIGNING_ALLOWED=NO','SWIFT_ACTIVE_COMPILATION_CONDITIONS='+flags,'build']
record={'command':cmd,'source_manifest_sha256':h(b/'source-manifest.json'),'started_at':datetime.datetime.now(datetime.timezone.utc).isoformat()}
with (e/(lane+'-build.log')).open('w') as log:p=subprocess.run(cmd,stdout=log,stderr=subprocess.STDOUT)
record.update(exit_code=p.returncode,finished_at=datetime.datetime.now(datetime.timezone.utc).isoformat());(e/(lane+'-build.json')).write_text(json.dumps(record,indent=2)+'\n')
if p.returncode:print('build failed',p.returncode);sys.exit(p.returncode)
entitlements={'application-identifier':'jp.ox.doorbell.t35modernuitest','keychain-access-groups':['jp.ox.doorbell.t35modernuitest'],'platform-application':True};(b/'app-entitlements.plist').write_bytes(plistlib.dumps(entitlements))
app=b/'xcode/Build/Products/Debug-iphoneos/DoorbellIOS9.app';info=plistlib.loads((app/'Info.plist').read_bytes())
for file in list(app.rglob('*.dylib'))+[app/info['CFBundleExecutable']]:subprocess.run(['ldid','-S'+str(b/'app-entitlements.plist'),str(file)],check=True)
entitlements={'com.apple.frontboard.launchapplications':True,'com.apple.private.MobileContainerManager.allowed':True,'com.apple.private.mobileinstall.allowedSPI':['InstallForLaunchServices'],'com.apple.private.security.container-required':False,'platform-application':True};(b/'register-entitlements.plist').write_bytes(plistlib.dumps(entitlements))
sdk=subprocess.check_output(['xcrun','--sdk','iphoneos','--show-sdk-path'],text=True).strip();registration=['xcrun','clang','-arch','arm64','-miphoneos-version-min=12.0','-isysroot',sdk,'-fobjc-arc','-framework','Foundation','-framework','UIKit','-framework','CoreGraphics',str(r/'tools/verification/ios_visitor_runner/register.m'),'-o',str(b/'register')];subprocess.run(registration,check=True);subprocess.run(['ldid','-S'+str(b/'register-entitlements.plist'),str(b/'register')],check=True)
meta={'bundle':info['CFBundleIdentifier'],'version':info['CFBundleShortVersionString'],'build':info['CFBundleVersion'],'lane':lane,'minimum_os':info['MinimumOSVersion'],'source_manifest_sha256':h(b/'source-manifest.json'),'artifact_files':{str(f.relative_to(app)):h(f) for f in sorted(app.rglob('*')) if f.is_file()},'registration_helper_sha256':h(b/'register'),'registration_build_command':registration,'signing':'ldid platform-application, own keychain group jp.ox.doorbell.t35modernuitest'};(b/'artifact-manifest.json').write_text(json.dumps(meta,indent=2)+'\n');print('build and sign PASS',lane)
