# 住户使用指南 —— 应答来客

> English: [Usage-Residents](Usage-Residents) / 日本語: [Usage-Residents-ja](Usage-Residents-ja) / 繁體中文 (本頁)

以家人的日常視角，用場景說明「這種時候該怎麼做」。哪些電話、app、integration 與 device 會
反應，取決於已 commissioning 的 hardware 與 matching rule。修改配置的方法見
[管理员指南](Usage-Admin-zh)，功能一览见[功能总览](Features-zh)。

## 场景 1: 在家时门铃响了

matching rule 對 commissioned indoor station 時，可顯示**入口、事由、訪客語言**，並在
source/playback path available 時顯示影像。以下 4 種是 conditional capability，不代表每個部署都有。

1. **在室內機接聽** —— real SIP/audio path commissioned 後，「接聽」使用已實作 audio/media profile。
2. **用电话接听** —— matching SIP/PSTN rule 與 commissioning 完成的 PBX path 可用時，內線或
   已登記手機可以響鈴。像平常一樣接聽即可和門口通話。
3. **用快捷回复回应** —— 按下「请稍等」等按钮即可。会以大字显示在门口机上
   并被朗读。做饭腾不出手的时候很方便。
4. **用 TV 遙控器回覆** —— rule 選擇的 commissioned Android TV path 可使用 incoming UI 與 D-pad
   quick reply；media 只有在實測 profile available 時才開始。

用电话接听之后如果「还是想用室内机说」，按室内机的「应答」就会
挂断电话侧并切换为室内对讲（应答接管）。

### 只想看看情况（不想应答）

用室内机或 TV 的「监视」，可以**单向**确认门口的影像和声音。这边的声音
完全不会被送出。如果对方看起来像推销，直接用「不需要，谢谢」的快捷回复收尾即可。

## 场景 2: 外出时有来客

- **matching Telegram rule 啟用時**，通知可包含照片、事由、語言 badge 與已配置的 quick reply button。
- **matching SIP/PSTN rule 與 commissioning 完成的 PBX path 可用時**，手機也可以響鈴。接聽即可
  和門口通話；已配置的 DTMF action（例如 *1）可能用於開鎖。
- **iPhone 的家庭 App**（已配置 HomeKit 联动时）也会出现门铃通知，可以确认
  实时影像。在外面查看需要 Apple TV / HomePod 的家居中枢。
- **能架 VPN 的人**，只要进入宅内 LAN，网页面板、管理界面、浏览器通话等
  全部功能都能原样使用。

无论通过哪条路径应答，其他家人的屏幕上都会显示「已应答」，防止重复应对。

## 场景 3: 只想收快递的日子

可以拜托管理员（或自己在管理界面）设置成「快递就自动朗读『请放在门口』，
并且不响电话」的规则。快递员按下事由按钮的那一瞬间
门口机就会回答，谁都不用做任何操作。详情见[管理员指南](Usage-Admin-zh)的配方集。

## 场景 4: 紧急的时候 (SOS)

**长按室内机的紧急按钮 3 秒**即触发报警（长按是为了防误触）。

- SOS active 狀態會複製到所有 Core node，node 重新連線時會恢復。
- visual alarm、sound、system notification、Web Push、Telegram、MQTT、SIP 目的地、Home Assistant
  action 只在 matching rule 選中時執行。rule 可以刻意設為零 recipient 或 silent presentation。
- 開啟中的 Web page 其 `emergency.web_active_page_alerts` 預設為 `true`，所以零 recipient 或
  Push-only rule 仍會渲染 SOS active/clear 狀態。管理員關閉後，正向匹配的 `device_alert` 或實際
  送達的 Push 仍可顯示。啟用期間，即使 rule TTL 結束 custom sound/color decoration，安全的紅色 SOS
  overlay 仍保留至 clear。page 把管理員指定的 `?group=` 同時用於 poll 與 Push。

**clear** 是需要已配置 PIN/permission 的授權操作。clear 狀態會複製到所有 Core node；device 是否
顯示 clear 或送出另一則 clear 通知，仍取決於 rule 與 Web switch。

管理界面的 delivery diagnostics 中，`delivery_result` 只表示 Core 嘗試 dispatch，不能證明 screen、
sound 或 system notification 真正呈現；證據來自 client runtime 的逐 channel presentation report。

重要的事: **不会自动呼叫警察或消防**。是否报警的判断必须由人来做，
这是设计使然（参见[设计理念](Design-Philosophy-zh)）。需要的话可以在配置中
添加向用户自定义号码（家人的手机等）的 SIP 呼叫。

## 夜间的行为

- **quiet_hours**（默认 23:00–07:00）: matching rule 可用這段時間抑制或改變指定 action。它不
  保證 phone、Telegram、HA 或其他 channel 一定執行；請在管理界面檢查 active rule。
- **夜间模式**（默认 22:00–06:00）: 门口机、室内机的屏幕减光，显示偏红。
  这是为了不让走廊变得刺眼的功能。
- 也可以组建「仅夜间的动体检测发到 Telegram」这样的规则（[管理员指南](Usage-Admin-zh)）。

## 记住了会很方便的小知识

- 可以从室内机「推送」主题（门口机的背景）和文案 —— 比如换成节令问候。
  更改会毫秒级反映到所有设备。
- 未接聽訪客會留在 event history；只有所選 camera path 成功產生時才附 snapshot。
- 若配置了 offline-device rule，node 從 LAN 消失時可以送 Telegram 或其他指定 alert；delivery 取決於
  該 rule 與所選 integration。
