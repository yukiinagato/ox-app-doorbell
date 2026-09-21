# main 复核补遗：已验证 `findings.json`

压缩包 `ox-app-doorbell-e76100b-main-review.zip` 的 SHA256SUMS 已全部验证，随后按入口顺序重读了其中的 `review-main-e76100b.zh.md` 与 `findings.json`。此前报告中“找不到 findings.json”的表述不正确，现由本补遗取代。

`findings.json` 的八组事项与已实施的 M01–M08 一致，但其逐项验收清单比此前报告更细。当前逐场景证据、生产入口、命令和未运行项已记录在 `verification/review-main-e76100b-findings-coverage.json`。该文件明确将未运行的真实 Windows、iPad mini 1/iOS9.3.6/armv7、浏览器/媒体与目标解码器资格保持为 `NOT_RUN`，不会由 host 或交叉构建替代。

本补遗没有新增生产代码、没有撤回已通过的命名回归，也没有 push、合并、发版、部署或设备安装。
