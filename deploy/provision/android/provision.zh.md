> 日文原文: provision.ja.md（以日文为准）

# Android 门口机的部署（kiosk / Device Owner）

对象: `android/` 的门口机 App（`jp.keihan.doorbell`）。minSdk 21 — 把 Android 5.0 及以上的
废旧平板/手机转用为门口机。相当于 Windows 版的
`deploy/provision/windows/provision.cmd` 的步骤。

## 1. 事前准备（设备侧）

1. 将设备**恢复出厂设置**（设置 → 系统 → 重置）。Device Owner 化只能在
   「未添加账号的初始设置刚完成时」进行。
2. 初始设置时**不要添加 Google 账号**（跳过）。
3. 启用开发者选项（连点版本号 7 次）→ 打开 **USB 调试**。
4. 把 Wi-Fi 接入宅内 LAN（mesh 前提是同一网段 — docs/zh/network-ports.md）。

## 2. contract build 與 controlled install

```sh
# modern development/contract
cd android && ./gradlew -PdoorbellTier=modern \
  assembleModernDebug testModernDebugUnitTest lintModernDebug

# API 19 development/contract（NDK/PJSIP cache 分開）
./gradlew -PdoorbellTier=legacy19 \
  assembleLegacy19Debug testLegacy19DebugUnitTest lintLegacy19Debug
```

repository/hosted CI 產生的是 debug key **debug-contract** APK，不是 release。現在 Gradle `release`
build type 也仍選用 debug signing config，因此不得把 `assemble*Release` 結果當 production 發佈。
controlled release 必須另用 approved signing config，記錄 artifact/toolchain/NDK/API/ABI/real-PJSIP hash/
source revision/signing identity，並只 install exact device 對應 tier。API 19 allowlist 目前為空，單是
install/probe 成功不會成為 supported KitKat SKU。

## 3. Device Owner 化（完全 kiosk 必需）

```sh
adb shell dpm set-device-owner jp.keihan.doorbell/.AdminReceiver
```

成功时显示 `Success: Device owner set to package jp.keihan.doorbell`。

- `java.lang.IllegalStateException: Trying to set the device owner, but device owner is
  already set` → 重做步骤 1 的初始化（残留了已有账号/已有 DO）。
- 成为 Device Owner 后，本 App 会通过 `setLockTaskPackages` + `startLockTask`
  **完全钉住**: 状态栏、主页、返回、最近任务全部失效。
- **锁屏**: DO 时启动即自动禁用（`setKeyguardDisabled` + 供电时常亮 +
  推迟系统更新弹窗）。**非 DO 设备须手动把 设置 → 安全 → 屏幕锁定 设为「无」**
  （进入锁屏会挡住来铃画面 — 来铃 Activity 本身有 showWhenLocked 可以出现在
  锁屏之上，但平时的待机画面会被覆盖）。

## 4. 放置 boot.json

App 首次启动会在 `filesDir/boot.json` 生成默认值。Core 启动前必须选择 **门口机** 或 **室内机**。
门口机还必须设置 door ID，界面会预填可直接确认的随机 `door-xxxxxxxx`。之后如果 role 非法或门口机 ID
丢失，同一设置界面会再次出现；室内机不配置 door assignment。不得把 mesh PSK 写入此文件。
初次部署应优先使用 App 内配对：Core 先调用 `secure_put("mesh.psk")`，只有成功后才记录
`{ "t": "paired", "psk_ref": "secret:mesh.psk" }`。
出现 `pairing_persistence_error` 的设备**不处于 ready 状态**，不得加入 mesh。

受管理设备如需预配置，必须先通过获批的带外流程把 `mesh.psk` 写入平台 secure store，
之后才可在 `boot.json` 中使用下列非秘密引用。只复制 `psk_ref` 不会写入秘密，也不会完成配对。

```sh
adb shell "run-as jp.keihan.doorbell cat files/boot.json"   # 确认（仅 debug 构建可 run-as）
cat > boot.json <<'EOF'
{ "name": "genkan-front", "role": "door_station", "door": "d_front",
  "listen_port": 47172, "http_port": 47180, "psk_ref": "secret:mesh.psk",
  "seed_peers": ["10.0.1.10:47172"], "ui_lang": "ja", "kiosk": true }
EOF
adb push boot.json /sdcard/boot.json
adb shell "run-as jp.keihan.doorbell cp /sdcard/boot.json files/boot.json"
adb shell rm /sdcard/boot.json
```

release 构建（不能 run-as）应通过已认证的管理 webui
（`http://<设备>:47180/admin/`）或经 DO 的 managed configuration 设置非秘密字段。
两条路径都不得携带明文 PSK；secure store 必须通过独立操作进行配置。

## 5. 替换 HOME（启动器）与自动启动

MainActivity 带有 `android.intent.category.HOME`。若 kiosk=true:

```sh
# 设为默认主屏（机型自带设置 UI: 设置→应用→默认应用→主屏应用 → 门铃）
# 已 DO 化的话也可以用 adb:
adb shell cmd package set-home-activity jp.keihan.doorbell/.MainActivity
adb reboot   # 重启并确认自动启动 (BOOT_COMPLETED + HOME)
```

## 6. 管理入口（解除 kiosk）

- 在屏幕**右上角的透明区域（200dp 见方）5 秒内连点 7 次** → 输入 PIN。
- PIN 为 `filesDir/exit_pin.txt` 中的 SHA-256 hex。文件不存在则为默认 `000000` —
  **安装时务必修改**:

```sh
printf '%s' '123456' | shasum -a 256 | cut -d' ' -f1 > exit_pin.txt
adb push exit_pin.txt /sdcard/ && adb shell "run-as jp.keihan.doorbell cp /sdcard/exit_pin.txt files/"
```

- 失败 5 次锁定 10 分钟（进程内）。成功则解除 lock task 并关闭 App。

## 7. 完全撤除 kiosk（拆机时）

```sh
adb shell dpm remove-active-admin jp.keihan.doorbell/.AdminReceiver   # 解除 DO (依 API 而定)
# 解除不了的机型，恢复出厂设置最可靠
adb uninstall jp.keihan.doorbell
```

## 8. Android TV（室内监视器）

把同一个 APK 装到 Android TV 上就成了室内监视器: 门铃被按下时，来客监视画面会
全屏盖在正在观看的画面之上，播放门口摄像头的直播视频 + 门口麦克风的声音。
可用电视遥控器（D-pad）选择快捷回复来应答。

### 8.1 连接与安装

```sh
# TV 侧: 设置 → 设备设置 → 开发者选项（版本号连点 7 次）→ 打开 USB/网络调试
adb connect <TV的IP>:5555
# 只安裝 approved tier artifact，不用 CI debug-contract APK 代替。
adb install -r <approved-apk-path>
```

### 8.2 boot.json（TV 是 indoor_panel）

仅在 App 内配对已成功，或获批的带外流程已把 `mesh.psk` 写入 TV 的平台 secure store 后，
才可使用以下形式：

```sh
cat > boot.json <<'EOF'
{ "name": "living-tv", "role": "indoor_panel",
  "listen_port": 47172, "http_port": 47180, "psk_ref": "secret:mesh.psk",
  "seed_peers": ["10.0.1.10:47172"], "ui_lang": "ja", "kiosk": false }
EOF
adb push boot.json /sdcard/boot.json
adb shell "run-as jp.keihan.doorbell cp /sdcard/boot.json files/boot.json"   # debug 构建
adb shell rm /sdcard/boot.json
```

kiosk 为 **false**（TV 平时当电视用）。在管理页面把
`devices.<tv_node_id>.local.tv = true` 立为标记（docs/zh/config-schema.md）。

### 8.3 权限（来客时盖到前台的必需设置）

Android 10+ 限制从后台启动界面。在 TV 上允许「显示在其他应用上层」
即可豁免（仅用 adb 就能完成）:

```sh
adb shell appops set jp.keihan.doorbell SYSTEM_ALERT_WINDOW allow
# 监听不用 SIP，但确认一下: 通知（常驻服务用, Android 13+）
adb shell pm grant jp.keihan.doorbell android.permission.POST_NOTIFICATIONS 2>/dev/null || true
```

能做 Device Owner 的 TV（刚初始化）也可以按 §3 做 DO 化，但 TV 主要用途是看电视，
通常上述 appops 就够了。

- 常驻: 前台服务（1 条通知）+ BOOT_COMPLETED 启动。TV 的省电 kill 较宽松，但
  首次要从启动器打开一次 App 以启动常驻。
- 来客时是否响铃取决于 fleet 配置的 trigger_rules（chime 动作）— 省略 devices 时
  以全部 indoor_panel 为对象，因此 TV 默认会响。

### 8.4 语音监听与 Asterisk

TV 的监听**不经 Asterisk**。TV → 门口机的 SIP 监听端口（UDP `sip.direct_port`，
默认 47190）直接发 INVITE（`X-Doorbell-Mode: monitor`），门口机仅把麦克风声音
单向送回（在家一侧的声音不会外流）。因此:

- **无需改动 Asterisk 侧配置**（不用改 dialplan、不用给 TV 建内线账号）。
- 即使家里没配置 config `sip.server`，TV 监听也能工作。
- 门口机在 Asterisk 通话中（呼叫中）也能追加受理监听呼叫（最多 2 路）。
- 若收紧 LAN 防火墙，需在子机之间放行 UDP 47190 (SIP) 与 UDP 4000-4099 (RTP)
  （docs/zh/network-ports.md）。

### 8.5 验证

1. 按门口机的呼叫按钮（或 `curl -X POST http://<门口机>:47180/api/press`）。
2. TV 观看画面之上出现来客监视，画面 + 门口的声音都出来。
3. D-pad 上下选回复并确认 → 门口机面板显示 + TTS 朗读 → 「已发送」。
4. 按 BACK（返回）关闭 → 监听呼叫挂断（门口机日志: 监视呼叫 结束）。
