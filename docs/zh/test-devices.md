# 本地测试设备

## iPad Air 1

用户于 2026-09-22 指定为 Doorbell 测试机。它与既有的 iPad 1、iPad mini 3
是不同设备。

| 项目 | 已验证值 |
| --- | --- |
| 型号 / 架构 | iPad Air 1 蜂窝版，`iPad4,2`，arm64 |
| 设备名 / 系统 | `iPad (2)`，iOS 12.5.8（16H88） |
| USB UDID | `b05d91834431516e147fbc99c8f0bdc34ec38c32` |
| Wi-Fi IPv4 / SSH 端口 | `10.10.38.199:44` |
| Wi-Fi MAC | `78:3a:84:a9:13:f3` |
| SSH 用户 / 认证 | `root`，专用 Ed25519 密钥；LAN 禁用密码登录 |
| 本机 SSH 别名 | `doorbell-ipad-air1` |
| 登记时应用版本 | Doorbell 0.1.36，构建 37，`jp.ox.doorbell` |

### 从这台 Mac 连接

```sh
ssh doorbell-ipad-air1
ssh doorbell-ipad-air1 'uname -m; ifconfig en0'
scp -O artifact.tar.gz doorbell-ipad-air1:/private/var/tmp/
```

别名位于 `/Users/ox/.ssh/config`；私钥为
`/Users/ox/.ssh/doorbell_ipad_air1_ed25519`；服务器身份固定在
`/Users/ox/.ssh/known_hosts_doorbell` 的 `doorbell-ipad-air1` 条目中。
不要把私钥或密码写入项目、日志或记忆。其他电脑需要单独授权自己的密钥；
本机别名不会自动赋予远程或云端 AI 访问权限。

已实测由 `10.10.38.24` 直接连接 `10.10.38.199:44`，采用密钥认证和严格主机
身份校验。主机密钥取自已验证的 USB 连接。已重新加载保存的 launchd 配置，
并再次验证 LAN 登录；LAN 服务只提供公钥认证。

### 服务和恢复

使用 checkra1n 自带的 `/binpack/usr/sbin/dropbear`。独立服务
`jp.ox.doorbell.test-ssh-lan` 通过 socket 激活，仅监听上述 Wi-Fi IPv4 地址。
配置文件为 `/var/root/doorbell-test-device/jp.ox.doorbell.test-ssh-lan.plist`，
授权公钥位于 `/var/root/.ssh/authorized_keys`。原有回环端口 44 仍可通过 USB 使用。

该 IP 来自 DHCP，未设置路由器地址保留。地址变化后，通过 USB 读取 `ifconfig en0`，
更新服务 plist 的 `Sockets.LANListener.SockNodeName` 和 Mac 别名的 `HostName`，
重新加载服务并验证 LAN。USB 成功不能代替 LAN 验证。

```sh
iproxy -u b05d91834431516e147fbc99c8f0bdc34ec38c32 2248:44
```

在另一个终端执行：

```sh
ssh doorbell-ipad-air1-usb 'ifconfig en0'
ssh doorbell-ipad-air1-usb 'launchctl load /var/root/doorbell-test-device/jp.ox.doorbell.test-ssh-lan.plist'
```

USB 别名使用同一密钥及主机身份。修改已加载的服务后，先对同一 plist 执行
`launchctl unload` 再加载。本次没有重启系统。完整重启会使当前 checkra1n 环境
失效；重新越狱后，需要经 USB 再次加载此 plist。文件保存在 `/var/root`，
不会作为系统 LaunchDaemons 自动加载。

### 应用维护

登记时应用路径为
`/private/var/containers/Bundle/Application/64FD671A-D11A-464E-8D6B-C2A35A9F31F0/Doorbell.app`。
更新前用 `uicache -l jp.ox.doorbell` 读取当前路径。应用 home 报告为 `/var/mobile`。
启动方式：

```sh
ssh doorbell-ipad-air1 '/binpack/usr/local/bin/lsdtrip.arm64 launch jp.ox.doorbell'
```

该精简越狱环境的根文件系统只读。已部署的应用使用 platform-application 签名权限
并通过 LaunchServices 注册；自带 `uicache -p` 不接受 `/Applications` 以外的路径。
不要套用 iPad mini 3 的安装路径。不同签名配置应分开存放，部署后从设备核对版本及
构建号。启动成功或进程存在不能证明界面、配对、SIP 或媒体功能通过验收。

遵循用户现有测试机约定：不备份测试机应用包、数据或文件。日常维护优先仅重启应用。
