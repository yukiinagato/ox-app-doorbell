# 访客体验 —— 门口机前会发生什么

> English: [Usage-Visitors](Usage-Visitors) / 日本語: [Usage-Visitors-ja](Usage-Visitors-ja) / 繁體中文 (本頁)

这一页不是「访客手册」—— 访客不会读说明书。
它是**为了部署者设计访客动线**，以访客的视角追踪门口机前发生的事。

## 待机画面上能看到什么

- **大呼叫按钮** ——「タッチして呼び出してください（触摸以呼叫）」。犹豫的话按这一个就够了。
  （文案、背景部署者可自由更改 —— [管理员指南](Usage-Admin-zh)的主题/文案）
- **事由按鈕** —— 訪問 / 快遞 📦 / 郵件 ✉️ / 推銷・收款 💼 / 抄表・施工 🔧 / 其他。
  `purpose_first` 在選擇事由後提交 ring；`ring_then_purpose` 先 ring，再顯示事由、略過事由與取消呼叫。
- **语言按钮** —— 日本語 / English / 中文（部署者通过 `ui.languages` 选择）。
  切换后画面的全部文案立即变为该语言。

夜间画面会减光、偏红，持续无操作会落入屏保（时钟），
但一触摸就立刻回到待机画面。

## 按下之后会发生什么

1. `purpose_first` 送出前，Back/Cancel 只回到 home、不發 event。送出後顯示「呼叫中……」與醒目的
   「取消呼叫」。
2. 配置的 rule 可執行 device chime、SIP call 或 integration；若 rule、target capability 或 service 不可用，
   不保證該 action 執行。
3. 应答有 3 种形式:
   - **通话** —— 扬声器里传来住户的声音。对着门口机的麦克风正常说话即可。
   - **快捷回复** —— 画面上以**大字**显示「请稍等」等，
     同时被朗读出来。显示约 30 秒后消失。
   - **自动应答** —— 视配置而定，按下的瞬间就返回回答
     （例: 快递 → 「请放在门口」）。
4. ringing 中「取消呼叫」會全域 cancel 相符 `call_id`，停止未接通 SIP leg 與尚未執行的 rule action。
   通話建立後改為「結束通話」並使用 hangup，不再稱為 cancel。
5. 到配置 TTL（未設時 60 秒）仍無人接聽，origin station 只送一次冪等的全域 cancel 並回 idle。
   已送出的外部 message 不保證撤回。

crash 後 ringing call 由 press-origin station 還原；in-call browser session 只有勝出的 dialog owner 能
還原。10 秒內無法證明時，Core 只送一次全域 cancel，不留下曖昧 call。

## 语言切换的细节行为（设计上的用心）

- 访客切换了语言这一事实，会以「🌐 EN」这样的徽标传达给住户侧。
- 住户发回的快捷回复，会**以访客所选语言的标签显示、朗读**
  （若未登记译文则回落到日语）。这是为了防止「英语访客只听到日语语音」
  这种事故的机制。
- 无操作持续 60 秒（配置 `ui.visitor_lang_revert_s`）后自动回到日语。
  这是为了让下一位访客不继承上一位访客语言的恢复计时器。

## 系统故障时访客看到什么

- 即使网络降级，只要呼叫送达就显示「已呼叫，请等待应答」。
- 完全离线时则诚实显示: 「**无法呼叫。请直接敲门。**」
  —— 这是为了不让访客站在一块沉默的板子前的最终回退。

## 面向部署者: 设计访客动线的提示

- **要有减少事由的勇气**。按钮越多，越容易被逃到通用按钮上。快递、邮件占
  大头的家庭，这 2 个 + 其他就足够了（在事由标签页编辑、排序）。
- **自动应答只用于「能承诺的回答」**。「请放在门口」是好的自动应答，
  但「马上就来」不可以自动播放。
- 使用**自定义语音**比 TTS 更容易听清，也能带出家的氛围。可以按访客语言
  分别登记录音（[管理员指南](Usage-Admin-zh)的资产/快捷回复）。
- **摄像头的朝向与高度**: Telegram 通知和事件历史的快照来自门口机的
  前置摄像头。请安装在能拍到脸的高度、不会逆光的朝向。
- 沒有 commissioned audio path 的入口要明確顯示 notification-only fallback。iPad 1 有 mic/speaker、
  沒有 camera，也不是 outdoor-rated。作為受保護的 visitor UI 前，須完成實機 audio/recovery test，並
  明確設定 LAN IP-camera 或 no-video profile；iPad 本身不提供訪客影像（見 [FAQ Q14](FAQ-zh)）。

相关: 功能全貌见[功能总览](Features-zh)，住户侧的视角见[住户使用指南](Usage-Residents-zh)。
