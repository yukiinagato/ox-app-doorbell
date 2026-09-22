# T24 执行报告

状态：VERIFIED_IN_SCOPE（native_source）。门口机与室内机主页日期均改用现有 i18n/strings.yaml 的 date.full/day.* 三语资源；删除两个固定日文星期数组。Core 已提供的日期和星期是唯一输入，未增加系统时钟、默认时区、java.time 或新 Android API。日期显示以格式化文本判重，语言切换立即更新，跨午夜随新的 Core 日期刷新。

生产格式逻辑 ClusterDateText 由 Texts、MainActivity 和 DashboardView 共用；保留语言覆盖配置。测试加载真正生成的三语 XML 资源，覆盖 ja/en/zh 往返切换、三种互异设备时区、跨午夜和无法取得日期时不使用 OS 时钟兜底。

modern 与 legacy19 分别实际运行 4 项定向单元测试（非缓存），全部 PASS；legacy19 lint PASS。T24-01 对应语言切换，T24-02 对应设备时区差异，T24-03 对应午夜/缓存，T24-04 对应 API 19 编译及 lint。原始日志、JUnit XML、命令与来源文件哈希在 evidence/ 和 source-final.json。未将编译错误或静态复制模型当作修复前业务反例；原实现的固定格式/星期数组由源审计确认。

本轮 Android 已递增至 0.3.21/build22；i18n生成及英文源检查均通过。APK完整构建和真机 UI 属于后续平台门禁；当前未发现可用 Android 真机，不能把本卡主机测试当作设备资格。
