# 本机开发环境与开发验收记录

检查日期：2026-10-01  
当前开发约定：日常开发使用模拟器；M7 真机业务验收及个人试用安装已完成。本文件按阶段保留历史记录，最新状态见末尾及 [M7 记录](m7-acceptance.md)。
状态：M7 个人试用交付完成，51 项领域/持久化/性能测试与 13 项 UI 场景分别通过，Release 已安装。最新验收见末节；下方保留前期历史记录。

## 已完成

- 已初始化本地 Git 仓库，当前分支为 `main`，尚未创建提交或配置远程仓库。
- 已设置 Swift/Xcode 构建产物、个人数据、导出、备份和密钥的忽略规则，并检查忽略规则生效。
- 已生成 `LotBill.xcodeproj`，包含 App、单元测试和 UI 测试三个 Target，以及共享 `LotBill` Scheme。
- 工程配置为 Swift 6、SwiftUI、SwiftData、最低 iOS 18，无第三方依赖。
- 已编写最小存储验证页。该页只用于输入合成测试文字，使用独立开发验证数据库，不是正式账本。
- 已运行通过容器重建后的持久化单元测试，以及 App 退出、重启后的 UI 测试。
- 已准备独立的 UI 测试数据库，避免 UI 测试使用普通开发记录库。
- 已准备历史期间、每日明细和月末对账的 JSON 合成样本，以及 5 大类、27 子类名称。
- 已提供只读环境检查脚本 `scripts/check-environment.sh`。

## 环境现状

| 项目 | 结果 |
| --- | --- |
| 系统 | macOS 27.0.1，Apple Silicon |
| 当前开发目录 | `/Applications/Xcode.app/Contents/Developer`，首次启动后自动生效 |
| 完整 Xcode | 已安装 Xcode 27.0，Build 27A266a |
| Swift | Apple Swift 6.4 |
| App Store 安装 | 首次获取窗口卡住；取消并重启后重试成功，安装完成并已启动 |
| iOS SDK / Simulator | iOS 27.0 SDK 与 runtime（24A434）已安装并通过运行测试 |
| 验收模拟器 | iPhone 18 Pro，iOS 27.0，arm64；UDID `76BE4108-39E0-4904-B45B-96328104C54B` |
| 真机 | iPhone 18 Pro Max，iOS 27.0（24A437）；已通过数据线连接并配对，开发者模式已确认 Enabled |
| Bundle Identifier | 默认 `app.lotlife.lotbill`；更换团队后原标识不可用，本机通过被忽略的 `LOT_BILL_BUNDLE_ID` 配置唯一开发标识，App 与测试 Target 派生各自标识 |
| Development Team | 已切换到用户重新登录的 Personal Team；Team ID 仅保存在被 Git 忽略的 `Config/Local.xcconfig` |
| 正式历史金额、月末账单、LLM 密钥 | 未提供；不影响使用合成数据准备工程 |

首次 App Store 安装窗口未提供可操作控件，用户也确认窗口卡住。取消该请求、退出并重新启动 App Store 后，重试成功并完成安装。备用 Apple Developer 登录页未登录、已关闭。Xcode 首次启动没有出现单独的许可确认提示，iOS runtime 已完成安装。没有启用额外的外部代理访问能力。

## 已执行的检查

| 检查 | 结果与限制 |
| --- | --- |
| `plutil -lint LotBill.xcodeproj/project.pbxproj` | 通过，工程配置语法有效 |
| PBX 文件引用、三个 Target、共享 Scheme、两个测试 Target | 结构检查通过 |
| `swiftc -frontend -parse` | 五个 Swift 文件语法解析通过；不是 SDK 类型检查或 iOS 编译证明 |
| `bash -n scripts/check-environment.sh` | Shell 语法检查通过 |
| 合成样本 | JSON 可解析；分类为 5/27；餐饮差额 150 元、交通差额 0；空白和零分开保存 |
| Git 忽略检查 | 个人文件、备份、导出、环境变量文件和本地配置被正确忽略 |
| iOS App 构建 | `xcodebuild … build` 成功，日志 `/private/tmp/lot-bill-build.log` |
| 测试工程构建 | `xcodebuild … build-for-testing` 成功，日志 `/private/tmp/lot-bill-build-for-testing.log` |
| 构建提示 | 工具提示没有 AppIntents 依赖而跳过元数据提取；当前 P0 未实现 App Intents，未出现编译错误 |
| 环境脚本 | 安装完成后执行通过，退出码 0；完整 Xcode、SDK、runtime 和可用 iPhone 均已识别 |
| 单元测试 | `PersistenceSmokeTests.testSavedRecordSurvivesReopeningStore` 通过，容器重建后记录仍存在 |
| UI 测试 | `LaunchPersistenceTests.testRecordSurvivesAppRelaunch` 通过，输入、保存、退出、重启后可读取记录 |
| 模拟器测试结果汇总 | `.xcresult` 确认 Passed：2 项通过、0 失败、0 跳过；runtimeWarnings 为空 |
| 真机启动 | 新账号签名、安装、证书信任及启动均通过；已移除本次旧账号两个验证 App，解除安装名额限制 |
| 真机持久化测试 | 单元测试通过；UI 测试重跑通过，验证输入、保存、终止 App、重启后记录仍存在 |
| 真机架构构建 | `generic/platform=iOS`、`CODE_SIGNING_ALLOWED=NO` 构建通过；日志 `/private/tmp/lot-bill-device-build.log`。仅证明 iOS 真机架构编译成功，不代表签名、安装或运行通过 |

## 模拟器验收证据

2026-10-01 12:43（Asia/Shanghai）测试完成。执行命令：

```bash
bash scripts/test-simulator.sh 76BE4108-39E0-4904-B45B-96328104C54B
```

- 测试运行日志：`/private/tmp/lot-bill-smoke-run.log`。
- 结果包：`/var/folders/jg/lz1pnn694_1dbn_l77vdlw0m0000gn/T/lot-bill-tests.EJVsQa/TestResults.xcresult`。
- 已使用 `xcrun xcresulttool get test-results summary --path …` 读取结果，确认两个测试都实际执行成功。
- 上述日志和结果包在临时目录中，可能被系统清理；验收结论已记录在本文。需要复验时重新运行脚本即可生成新结果包。
- 通过自动化接口打开 DeviceHub 设备窗口时发生超时；不影响已完成的模拟器启动和 XCTest 测试。没有据此宣称设备窗口展示成功。

## 保留待办与验收范围

1. 当前验证覆盖 iOS 27.0 的模拟器和真机；签名、安装与本地存储验证已完成。免费 Personal Team 的签名到期后需重新签名安装。
2. 最低部署版本暂设 iOS 18，本次只验证了 iOS 27.0；最低系统运行兼容性尚未验证，需后续兼容 runtime 或真机覆盖。
3. M1–M7 个人试用交付已完成；真实 LLM、最低 iOS 18、真实财务样本、更多机型和物理断电仍为明确限制，详见 M7 记录。
4. 真实历史金额、月末样本和服务配置按后续里程碑准备，当前使用合成数据。

详细步骤参见[开发计划](development-plan.md)。模拟器及真机环境门槛已通过，可进入 M1 正式账本模型和工程骨架开发。

## 更换签名账号后的复核

- 使用独立目录 `/private/tmp/lot-bill-device-new-account` 重新执行真机 `build-for-testing` 成功，避免复用旧标识的测试配置。
- App 和 UI 测试 Runner 均通过系统证书服务下的 `codesign --verify --deep --strict` 校验；Mac 钥匙串不再阻塞本次构建。
- 构建日志：`/private/tmp/lot-bill-new-account-build.log`。随后已在用户信任新证书后完成真机运行验收，见下节。

## 真机验收证据

2026-10-01 13:28（Asia/Shanghai）完成。设备为 iPhone 18 Pro Max，iOS 27.0（24A437）。

| 检查 | 结果 |
| --- | --- |
| 单元测试 `testSavedRecordSurvivesReopeningStore` | 13:25 首次运行通过；SwiftData 容器重建后读取正确 |
| UI 测试 `testRecordSurvivesAppRelaunch` | 首次被 iOS 无线数据授权弹窗打断；用户确认页面无弹窗后，13:28 单独重跑通过，1 项通过、0 失败、0 跳过 |
| App 正常启动 | 测试后用 devicectl 正常启动成功，便于手动体验 |

两项真机必要测试分别取得通过结果；没有将首次包含 UI 失败的整次运行标记为全部成功。

- 首次测试日志：`/private/tmp/lot-bill-device-trusted-test.log`。
- 首次结果包：`/var/folders/jg/lz1pnn694_1dbn_l77vdlw0m0000gn/T/lot-bill-device-tests.tFB87f/TestResults.xcresult`。
- 界面重测日志：`/private/tmp/lot-bill-device-ui-retry.log`。
- 界面重测结果包：`/private/tmp/lot-bill-device-ui-retry.xcresult`，已通过 xcresulttool 汇总确认 Passed，runtimeWarnings 为空。
- 复验入口：`scripts/test-device.sh`。首次出现无线数据提示时先由用户处理，再运行 UI 测试。测试过程中保持手机解锁，避免手动操作页面。
- 测试使用独立的 `DevelopmentUITest.store`；正常启动显示的是 `DevelopmentCheck.store`，不显示自动化测试记录属于预期行为。

日志和结果包位于临时目录，可能被系统清理。本次未导入真实账单，未执行任何真实金额迁移。

## M1/M2 模拟器开发验收（2026-10-01）

本轮仅使用 iPhone 18 Pro / iOS 27.0 模拟器，未部署或操作真机。Xcode 的默认运行目标已通过界面确认切换为 iPhone 18 Pro 模拟器。

### 已实现

- 独立 `Ledger-v1.store`、版本化 SwiftData Schema、仓储写入接口、校验和保存失败回滚。原 P0 文字验证库保留。
- 整数分金额、有效自然日期、月/年/区间精度，汇总使用溢出检查；历史部分覆盖显示未拆分，不伪造每月金额。
- 稳定分类种子：5 个支出大类、27 个支出子类及“其他收入”；账户不预造。
- 首页、流水、统计和设置；每日新增、补记、编辑、删除，按月份、类型、分类、账户筛选及搜索。
- 收入、支出、本人账户转账与关联退款。转账不计收支；退款按退款发生月冲减原分类，累计退款不可超额，原支出存在退款时保护关联。
- 月度与年度收支、分类图及精确数值列表；修改日期或分类后统计重算，受影响的已核对月份失效。
- 账户和分类新增、重命名、停用；历史引用保持稳定。无网络请求、无服务端依赖。

### 验证结果

18 项单元/持久化测试和 2 项 UI 测试在整套运行中通过；随后只调整键盘收起控件，再次单独执行 2 项 UI 测试也通过，运行警告为空。UI 测试覆盖：

1. 支出新增 → 首页统计 → 重启仍存在 → 编辑金额 → 统计更新 → 确认删除 → 重启后仍删除。
2. 创建账户 → 记录收入并选择账户 → 查看首页 → 流水搜索 → 查看统计。

首次扩展界面测试发现搜索框默认收起，已改为始终显示；切换标签前退出搜索，避免键盘遮挡。之后重新执行上述最终回归。

- 最终运行日志：`/private/tmp/lot-bill-ledger-acceptance.log`。
- 结果包：`/var/folders/jg/lz1pnn694_1dbn_l77vdlw0m0000gn/T/lot-bill-tests.RV0u78/TestResults.xcresult`。
- 构建目录：`/private/tmp/lot-bill-ledger-build`。
- UI 测试通过 `--ledger-test-store <UUID>` 使用独立账本，不写入正常模拟器账本。
- 真实数据、账号信息及密钥未进入测试数据或版本库。

### 本轮限制

历史、导入批次、对账依据和月度调整实体已作为基础模型建立，但导入、撤销、对账调整版本操作尚未开放，不视为 M3/M4 已实现。初始化覆盖缺口提示、分类排序、近期账户记忆、大字体与深浅色专项检查仍待补。最低 iOS 18 运行兼容性、业务规模性能及最终真机验收尚未完成。

### 最终界面复测与结果包

整套结果包经 xcresulttool 确认 20 项通过、0 失败、0 跳过；其中记录两条金额键盘弹出时的布局警告。已移除触发问题的键盘工具栏，改用表单中的“完成金额输入”控件与滑动收起键盘，再次执行受影响的两个 UI 场景，2/2 通过，runtimeWarnings 为空。

- 最终 UI 复测日志：`/private/tmp/lot-bill-ledger-keyboard-retest.log`。
- 最终 UI 复测结果：`/private/tmp/lot-bill-ledger-keyboard-retest.xcresult`。
- 页面截图：[记账首页](previews/daily-ledger.png)、[收入统计](previews/reports.png)，仅含合成数据。
- 整套运行测试完成后，Xcode 的 simctl diagnose 诊断采集长时间阻塞；仅终止该次诊断子进程，xcodebuild 随后正常退出 0，结果包确认 Passed。模拟器脚本现使用 `-collect-test-diagnostics never` 避免额外系统诊断，保留常规日志、测试结果与截图附件；最终 UI 复测已正常自动收尾。


## M3/M4 模拟器验收（2026-10-01）

本轮仅使用 iPhone 18 Pro / iOS 27.0 模拟器；未部署或操作真机。

### 交付

- XLSX / UTF-8 CSV 选择、工作表和行范围选择、A/B/C 或通用列映射、分类手动映射、期间/收支/金额分隔符确认。
- 空白/零、总计与小计、合并大类、共享字符串、公式缓存、范围外公式过滤；文件大小、行列数、压缩包展开、CRC 和 XML 安全边界。
- 原文件 SHA-256 与规范化数据防重，历史期间和明细/调整重叠冲突拦截，提交时重新校验，事务回滚与可预览撤销。
- 来源工作表/行号、历史原期间、覆盖空档提示；撤销保护已修改或被对账引用的历史以及已有核对/调整的对账版本。
- 月度文件和手动分类依据，人民币/全部账户、净支出与消费总额口径、缺失分类状态、差异流水跳转与补录。
- 有原因和方向确认的月度调整、旧调整替换和修订留存、月度依据版本替换、核对快照、保留未解决差异的说明、流水或调整变化后状态失效。
- V1→V2 轻量迁移；已有账本路径保持不变。导入、调整、核对与审计重启后保持一致。

### 证据

- 36 项单元/持久化测试：`/private/tmp/lot-bill-m4-unit-final.xcresult`，日志 `/private/tmp/lot-bill-m4-unit-final.log`。
- 4 项正常字号 UI 流程：`/private/tmp/lot-bill-m4-ui.xcresult`；0 失败、0 跳过，runtimeWarnings 为空。
- 1 项外观与大字体 UI 场景：`/private/tmp/lot-bill-m4-accessibility-final.xcresult`；对应首页、统计、导入预览截图经人工检查。修正最大辅助字号下的月份和收支布局、分类映射文字截断。
- UI 导入场景使用 DEBUG 专用合成 CSV 注入到独立 UUID 测试账本，经过真实解析、预览、提交和撤销；不操作用户的文件库。系统文件选择器本身未做端到端自动化，文件 URL 读取另有单元测试。
- CoreXLSX 0.13.0 / ZIPFoundation 0.9.19 / XMLCoder 0.11.1 已锁定，许可证全文在 `docs/licenses/`。合成 XLSX 测试动态构造实际归档，验证共享字符串、合并、缓存/缺缓存、范围外公式与异常归档。
- 修复后浅色常规字号复测：`/private/tmp/lot-bill-m4-light-final.xcresult`；新增异常工作簿重复单元格拦截后的相关解析/映射复测：`/private/tmp/lot-bill-m4-parser-final.xcresult`。
- 验收后模拟器恢复为原浅色、常规 large 字号。
- 截图：[历史导入](previews/history-import.png)、[月度调整](previews/monthly-adjustment.png)、[深色大字体首页](previews/accessibility-overview.png)、[深色大字体导入](previews/accessibility-import.png)。

### 剩余范围

本节记录的是 M3/M4 完成时的状态：当时 M5、M6 和 M7 尚未实现或完成；M5/M6 后续结果见下一节。真实财务样本、最低 iOS 18 兼容性、大规模性能和更多机型仍需最终验收。分类手动排序和最近账户记忆为体验待办，不影响本轮导入及对账闭环。


## M5/M6 模拟器验收（2026-10-01）

### 完成范围

- AI：Chat Completions 兼容服务配置、Keychain 密钥、无账本测试连接、每次发送确认、一句话候选草稿、本地分类优先、字段核实后保存、确定性统计月报。超时/断网/限流/取消/异常响应均保留手动入口；禁用重定向及网络缓存。
- CSV：流水、历史汇总、月度调整、对账比较分别导出；日期范围、可选历史版本、UTF-8 BOM、精确金额、转义及公式字符保护，提供预览及系统文件导出器。
- 备份：版本 1 逻辑 JSON，保留九类实体的稳定 ID、来源、审计、修订和关联，排除 AI 配置与密钥。恢复前校验和预览，先写本机恢复点再整体事务替换，失败回滚，恢复成功重建导航视图。
- 修正分类保护：已有对账项或调整引用的末级分类不能改成父级，保证正常账本可完整备份。

使用路径、协议、格式与边界见 [M5/M6 使用说明](ai-and-data.md)。

### 验收证据

全部仅使用 iPhone 18 Pro / iOS 27.0 模拟器，无本轮真机调用。结果按实际运行拆分记录，没有把早期失败的整次运行记为通过：

| 结果包（`/private/tmp/`） | 结果 |
| --- | --- |
| `lot-bill-m6-acceptance.xcresult` | 49 项单元测试和 7 项 UI 通过；2 项新 UI 因确认弹窗多重匹配及系统导出器定位失败，后续复测通过 |
| `lot-bill-m6-r3.xcresult` | 最终 50 项单元测试全部通过；两项 UI 定位问题继续修正 |
| `lot-bill-m6-r4.xcresult` | AI 草稿核实/入账/月报，以及 CSV 系统导出取消/恢复确认/重启持久化两项 UI 全部通过，15:48 完成 |
| `lot-bill-m6-ai-final.xcresult` | 清除勾选核实后的旧错误提示，AI 完整流程再次通过，15:49 完成 |

对应日志与结果包同名、后缀 `.log`。四份结果包的 `runtimeWarnings` 均为空。构建中仅出现未引入 AppIntents 的元数据提取提示，不影响构建及测试。

单元测试涵盖 Keychain 合成密钥往返与删除、兼容请求构造、限流重试、网络失败与取消、异常响应拒绝、最小发送内容、CSV 中文/转义/金额/类型隔离、全实体备份往返、同 ID 重复替换、磁盘重开、事务故障注入、恢复点写入失败、陈旧预览及损坏引用拒绝。

UI 新增四个场景：服务配置重启且不回显密钥；未配置服务的原文手动回退；未核实禁止保存、核实后入账 35 元并生成月报；CSV 预览、系统导出取消、恢复确认及重启后 35.50 元保持一致。此前五项记账、统计、导入、对账与辅助字号场景继续通过。

AI 核实后旧错误提示已即时清除并复测通过。截图为合成数据，保存在 `docs/previews/ai-review.png`、 `docs/previews/ai-report.png`、`csv-export.png`、`csv-system-picker.png` 和 `backup-restore.png`。已检查文字、按钮和滚动可达性。

### M5/M6 阶段尚待项（历史记录，M7 结果见下节）

- 未配置真实供应商/密钥，网络与模型输出使用 URLProtocol 或 DEBUG 测试响应；无真实 API 调用。
- 恢复 UI 使用 DEBUG 合成预览；真实文件 URL 的读取与校验由单元测试覆盖，用户文件选择→读取→恢复全链路留待 M7。
- 保存前故障、恢复点写入失败已有回滚验证；进程强杀、断电恢复和大规模性能尚未做专项实验。
- 最低 iOS 18、真实财务样本、更多机型、真机业务全流程，以及既有分类手动排序/近期账户记忆体验待办保持未完成。


## M7 真机与首版交付（2026-10-01）

已在 iPhone 18 Pro Max / iOS 27.0（24A437）完成合成业务验收。51 项领域/持久化/性能测试及 13 项 UI 场景分别取得通过结果。首次完整运行中 AI 确认按钮在系统中断后未成功触发、CSV 取消依赖错误的固定目录层级；相关两项修正测试交互并单独复测，不将早期失败运行当作全通过。

- 万条磁盘账本：统计 0.023 秒、查询 0.010 秒、恢复 0.630 秒，条数、总额和重开一致。
- 真正系统文件选择→历史初始化→每日 1200 元→月末依据 1350 元→调整 150 元→导出 JSON→增加 10 元→选回文件恢复→重启回到 1350 元→CSV 导出闭环通过。
- 提交前后突然退出均保留完整旧/新账本与原账本恢复点；保存后 SIGKILL 与重启一致性另验。物理断电和数据库写入中途断电未覆盖。
- 修复本机文件目录不显示、最大辅助字号流水金额拆行；深浅色、输入、日期、长列表均有截图证据；软键盘遮挡组合仍列为未覆盖。
- Release 0.1.0（1）已签名安装并正常启动。安装脚本、结果包、截图和完整边界见 [M7 验收记录](m7-acceptance.md)。
