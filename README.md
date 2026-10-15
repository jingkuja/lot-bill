# Lot Bill

iOS / macOS 原生个人记账 App。历史汇总一次导入，后续每日维护，月底补充与对账。

首版 0.1.0（1）已完成 M7 个人试用交付：支持收入、支出、本人账户转账、关联退款、流水编辑删除与筛选、月度年度统计，以及账户和分类维护。支持 XLSX/CSV 历史导入、批次撤销、月度对账及调整修订，新增可配置 AI 草稿（含微信/支付宝账单截图识别，需多模态模型）/月报、四类 CSV 导出及完整备份恢复。AI 草稿必须人工核实后保存，密钥仅存 Keychain。

**日常开发与调试使用本机模拟器；M7 最终验收使用真机。** Xcode 默认目标仍为 iPhone 18 Pro 模拟器。

- [原生 macOS 端：运行、快捷键、数据迁移与测试](docs/macos.md)
- [P1/P2 功能更新与使用说明](docs/p1-p2.md)
- [M7 验收、试用安装与已知限制](docs/m7-acceptance.md)
- [整体方案](docs/solution.md)
- [开发计划](docs/development-plan.md)
- [导入格式与对账规则](docs/import-format.md)
- [本机环境与验收记录](docs/environment.md)
- [AI、CSV、备份与恢复使用说明](docs/ai-and-data.md)
- [历史导入预览](docs/previews/history-import.png) / [月度调整](docs/previews/monthly-adjustment.png)
- [模拟器首页截图（合成数据）](docs/previews/daily-ledger.png) / [统计截图](docs/previews/reports.png)

## 开始开发

macOS 端：打开 `LotBill.xcodeproj`，选择 **LotBillMac → My Mac** 运行；测试使用 `bash scripts/test-macos.sh`。Mac 与 iPhone 复用业务和数据模型，各自保存本地账本，可通过 JSON 完整备份迁移，尚无自动同步。

iOS 端：安装完整 Xcode 和 iOS Simulator runtime 后，打开 `LotBill.xcodeproj`，选择 `LotBill` Scheme 和可用 iPhone 模拟器运行。

```bash
bash scripts/check-environment.sh
```

该检查只读取环境，不安装软件、不接受许可、不修改工具链。真机运行前，在 Xcode 的 Signing & Capabilities 中选择自己的 Team。当前 Bundle Identifier 是开发占位值，首次配置真机签名时确认其可用性。

```bash
xcodebuild -project LotBill.xcodeproj -scheme LotBill \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/lot-bill-derived-data build
```

`LotBillTests` 覆盖金额、日期、统计、退款、历史重叠、CSV/XLSX 解析、去重、撤销、对账调整、Schema 迁移、SwiftData 持久化、AI 异常与密钥、CSV 导出及备份故障回滚；`LotBillUITests` 覆盖记账、编辑、删除、重启、账户创建、收入、搜索与统计，以及 AI 人工核实、服务配置、导出取消和恢复。每个 UI 测试使用独立的合成账本。

```bash
xcrun simctl list devices available
bash scripts/test-simulator.sh <SIMULATOR_UDID>
```

将占位符替换为列表中的设备 ID。脚本会输出本次日志及 `.xcresult` 路径，并在测试失败时返回非零退出码。

## 最终阶段的真机验收

以下命令只在最终 M7 阶段使用，日常开发请使用上方模拟器入口。

Xcode 登录 Apple Account，iPhone 开启开发者模式、完成配对，并在首次安装后信任自己的开发者证书。测试时保持手机连接并解锁。

工程通过 `Config/Development.xcconfig` 加载被 Git 忽略的 `Config/Local.xcconfig`。本机已配置签名团队；新机器需要在该本地文件设置 `DEVELOPMENT_TEAM = 你的团队ID`。App 和两个测试 Target 继承此配置，不把个人 Team ID 写入共享工程。

本机更换账号后，原 Bundle ID 无法注册到新团队，因此已在本地配置设置唯一的 `LOT_BILL_BUNDLE_ID`。三个 Target 从它生成对应标识。新账号下安装的是独立开发 App，不会覆盖原团队的安装；默认标识仍为 `app.lotlife.lotbill`，没有本地配置时供模拟器使用。

```bash
xcrun devicectl list devices
bash scripts/test-device.sh <DEVICE_UDID>
```

脚本会请求 Xcode 使用已登录账号更新开发签名、登记指定设备并安装运行测试。免费 Personal Team 的配置有效期为 7 天，到期需重新签名安装。

完成签名配置后，安装个人试用的 Release 版本：

```bash
bash scripts/install-device.sh <DEVICE_UDID>
```

该脚本构建、安装并启动 App，使用同一 Bundle ID 保留现有应用数据。Release 不含 DEBUG 测试数据和注入入口。完整备份可保存到“文件 → 我的 iPhone → Lot Bill”；此本机目录随卸载消失，长期备份请另存。已知兼容性及验收边界见 [M7 记录](docs/m7-acceptance.md)。

## 本地账本

正常运行沿用 `Ledger-v1.store`，Schema V2 通过轻量迁移新增来源与核对审计，保留 V1 记录。P0 的文字验证库原样保留，不会混入正式账本。初次启动只建立稳定分类，不自动创建账户或消费数据。金额以整数分保存，按交易发生日期的自然月统计，收支结余不作为账户余额。

## 数据与依赖

`Fixtures/Synthetic` 中仅有合成数据；`history.csv` 和 `reconciliation.csv` 可通过文件导入入口试用。历史导入保留第一、第二分类的年度支出，支持编辑历史金额、分类与覆盖日期；2026 年仅覆盖 1 月 1 日至 8 月 31 日，不导入月度汇总。JSON 为领域样例，不能直接导入。格式与边界见[导入说明](docs/import-format.md)。

真实账单放入被忽略的 `PrivateData/`，本地备份和导出分别放入 `Backups/`、`Exports/`。密钥和 Team ID 不提交到仓库。

XLSX 使用 CoreXLSX 0.13.0、ZIPFoundation 0.9.19 与 XMLCoder 0.11.1；Swift Package Manager 锁定文件及许可证均已纳入工程。
