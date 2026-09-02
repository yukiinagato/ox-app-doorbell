# 安全維運

系統的信任邊界是可信任的家用 LAN，不可直接暴露於 Internet。遠端存取應置於妥善維護的 VPN
或有驗證的 TLS reverse proxy 後方，並限制 node port 僅供可信任網段使用。參見
[network ports](network-ports.md)。

## 秘密資料契約

- plaintext credential 不得出現在 CRDT、event、log、URL、diagnostics、export 或 `boot.json`。
- 一般 secret-bearing 設定只存 `psk_ref: "secret:mesh.psk"`、SIP/MQTT `pass_ref`、Telegram
  `bot_token_ref`、WebRTC `sip_pass_ref` 與 media source `secret_ref`；不可分割的 sealed Web Push
  subscription 例外見下文。
- 實值經 `db_platform_v2.secure_put`/`secure_get` 寫讀；Windows 使用 DPAPI、Android 使用 secure
  storage、iOS 使用 Keychain。新 pairing 由 Core 先完成 `secure_put("mesh.psk", …)`，之後只向 shell
  發出 `{t:"paired", psk_ref:"secret:mesh.psk"}`，不傳送 `psk_hex`。
- secure store 失敗時，Core 發出 `pairing_persistence_error` 而不發出 `paired`；client 必須維持
  not-ready。`psk_hex` 與舊 plaintext password/token 僅是遷移輸入。
- media URL 不得含 userinfo。必須明確設定 `media_sources.<id>.secret_ref`，不可從 seed peer
  推測 camera URL。

設定匯出刻意不含秘密實值；復原時須分開還原設定與每台裝置的秘密。
MQTT／Telegram 的 ref 會作為 fleet config 複製，但秘密實值不會複製。首次儲存或輪換後，請在每個可能
擔任該 integration leader 的節點上，使用 Admin 的「配置到此節點」把同一實值寫入目前的 ref；此操作
不改動 fleet config。所有預定候選節點回報 backend ready 前，不應宣稱故障切換已就緒。
SIP 密碼也只能在目標裝置自己的 Admin 中輸入；遠端列僅能修改非秘密 account metadata，不會把密碼
錯存到其他裝置的 secure store。

panel ref 與非秘密的 credential generation 會複製，但 token 實值不會。輪換會原子替換 ref 與
generation；綁定兩者的 panel session 在各節點收到該配置後都會被拒絕。請透過核准管道傳送只顯示一次
的輪換值，並在每個提供 Web panel 的節點上使用 **配置到此節點**。配置只允許目前被引用的 panel
secret，寫入本機 secure store 並使本機 panel session 失效；不修改 fleet 配置，也不回傳 secret 值。

Web Push subscription 的 bearer-like endpoint 與 `p256dh`/`auth` 會先 normalize，再作為一個完整值
seal。schema-v2 CRDT record 使用 mesh PSK 導出的 key 與 XChaCha20-Poly1305；materialized config、
diagnostics、export 不會暴露 plaintext。只有 subscription operation/provider delivery 需要時才在
bounded memory 中 open；delete 則從送入的 exact endpoint 導出 record key。啟動時會盡可能重新 seal legacy raw
record，否則 fail-closed 刪除；被刪除的 subscription 必須由 browser 重新登記。非秘密的 group/page
metadata 保存在 ciphertext 外；經驗證的 `?group=<name>` 會在 local 保存，供 state poll 與 Push
enrollment 共用。

轮换 mesh PSK 后，使用旧 PSK seal 的 record 会按设计无法 open。PSK 轮换或重新配对后，必须打开每个
已登记的 browser/profile，按所需 group 重新启用 Push，并完成一次实际投递后才能视为恢复。
`configured` 或 backend-ready 状态本身不能证明关闭中的浏览器已重新登记。

## access 與 transport 邊界

mesh 以 cluster PSK 驗證及加密。47180 的 Admin／panel route 使用各自的 session，但為相容 native
client、HA 與 go2rtc，`/stream.mjpeg`、`/stream.mp4`、`/snapshot.jpg`、`/video-meta` 與 exact
`GET /asset/<64-lowercase-hex-sha256>` 與 `/peer-frame.jpg` 刻意允許在 LAN 上無 session 讀取；其他 `/asset` method、
malformed hash 與 suffix path 仍需驗證或會被拒絕。必須把整個 47180 限制在可信任 media LAN，或置於有驗證的 TLS
reverse proxy 後方；panel cookie 並不是 video authorization。panel token 應視為秘密；移除接收者或
裝置時須輪換，且 token URL 不得寫入 log 或公開設定。舊 iOS 的 MiniSIP 僅供 LAN UDP/PCMU，沒有
TLS/SRTP。越獄裝置應放在隔離的可信任 LAN，由 operator 建立獨有的 host access credential。

optional root helper 只公開 fixed filesystem Unix socket，沒有 TCP、shell、arbitrary argv 或 reboot
operation。Android 驗證 stream `SO_PEERCRED` 與 heartbeat PID ownership；legacy Apple 依賴 root-owned
socket permission 加 heartbeat PID ownership。mode/status/safe-mode marker 經 symlink check 後原子替換，
其 parent directory 必須 root-owned。不得從 configured `helper_mode` 推測 availability。

## rotation 與 incident checklist

遭竊或洩漏時，先隔離裝置，輪換 mesh PSK 並重新 pair 其餘 node，再輪換 SIP/MQTT/Telegram/
WebRTC/media/admin/panel credential/token。先更新 secure store，並驗證舊值無法連線、backup/log
不含實值。

不得 commit Apple SDK、簽署 material、provisioning profile、private key、secure-store export、
生成 binary 或真實環境 address/credential。
