# 原生 macOS 端

现有 Xcode 工程新增 `LotBillMac`、`LotBillMacTests`、`LotBillMacUITests` 三个 Target，共享 Scheme 为 `LotBillMac`。使用 macOS SDK、SwiftUI 和 SwiftData，最低部署版本为 macOS 14.0；不是 Mac Catalyst。iPhone 的 `LotBill` Scheme 保持独立。

## 运行

用 Xcode 打开 `LotBill.xcodeproj`，选择 **LotBillMac → My Mac**，点击 Run。

```bash
xcodebuild -project LotBill.xcodeproj -scheme LotBillMac \
  -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/lot-bill-mac-derived build
```

产物为 `/private/tmp/lot-bill-mac-derived/Build/Products/Debug/LotBillMac.app`。Mac Target 默认使用本机 ad-hoc 签名，无需配置 iPhone 的开发团队；对外分发需另行配置 Developer ID 或 Mac App Store 签名及相应发布流程。不要把本机调试产物作为已公证的安装包分发。

## 界面与操作

- 单主窗口，侧边栏提供概览、流水、统计、历史导入、月度对账、AI 辅助和数据管理。
- 流水为原生表格，支持按列排序、月份/类型/分类/账户筛选、搜索；双击或选中后点击“查看记录”可编辑、删除。
- `⌘N` 记一笔，`⌘F` 跳转并聚焦流水搜索，`⌘,` 打开设置窗口。
- 记账窗口支持 Esc 取消和默认保存按钮；多行备注仍可正常输入换行。
- 分类排序在 Mac 使用上下箭头，在 iPhone 保留编辑拖动。
- 文件导入、CSV 导出和备份恢复继续使用系统文件选择器。
- AI 账单图片使用原生 `NSOpenPanel` 选择本地图片文件，限 32 MiB；本机压缩后交给配置的多模态 LLM 解析并生成待确认草稿。iOS 保留相册入口。

## 代码组织

Domain、Application、数据模型、Schema 迁移、CSV/XLSX 解析、AI 服务和备份校验在两个产品间共享。Mac 产品的 Swift 模块名仍为 `LotBill`，所以现有四个业务测试源文件无需复制。

`Features/MacLedgerViews.swift` 提供 Mac 导航、菜单和流水表格；`Features/PlatformViewModifiers.swift` 收敛键盘、标题、表单、搜索和弹窗尺寸的平台差异。`LedgerRepository.filteredEntries` 供两端共同调用。

共享源码新增文件时，需同时加入两个 App Target；修改工程后分别验证 `LotBill` 和 `LotBillMac` Scheme。

## 本地数据与权限

Mac Bundle ID 为 `$(LOT_BILL_BUNDLE_ID).mac`，继承本地 Bundle ID 前缀，但具有独立的应用沙盒、偏好设置和 Keychain 服务名。启用 App Sandbox，仅申请用户选择文件的读写权限与 AI 请求所需的出站网络权限。

Mac 的数据库位于其沙盒 Application Support 下的 Bundle ID 子目录，文件名仍为 `Ledger-v1.store`。iPhone 的存储位置和 V1 → V2 迁移方案不变。开发时保持 Bundle ID 不变，避免切换到一个新的空账本。

两端没有自动同步。可以从 iPhone 导出 JSON 完整备份，在 Mac 的“数据管理 → 备份与恢复”中预览、确认恢复。恢复会替换目标账本并建立本机恢复点，不会合并两端记录。AI 密钥不在备份中，需要在 Mac 单独配置。长期备份应导出到应用之外的独立位置。

## 测试

```bash
bash scripts/test-macos.sh
```

业务测试覆盖金额、退款、统计、持久化、Schema 迁移、导入、对账、AI、Keychain、CSV 和备份故障回滚；新增共用筛选测试覆盖大类、月份边界和转入账户搜索。Mac UI 测试使用随机 UUID 的独立合成账本，验证快捷键、取消、记账、表格搜索、重启持久化及设置窗口。

测试需要可用的 macOS 图形会话和 Xcode UI 自动化权限；运行时会操作被测应用窗口。测试日志和 `.xcresult` 输出到临时目录。

## 本次验证（2026-10-02）

- Xcode 27.0 / 本机 Apple silicon：macOS Debug、Release 构建通过；iOS Simulator 构建回归通过。
- 64 项共享业务测试通过，包含实际 Keychain 读写、磁盘重开、V1 → V2 迁移和万条合成流水。
- 两项 Mac 界面测试分别通过：记账、搜索、重启持久化；Esc 取消及原生设置菜单。`⌘,` 另经实际界面验证。测试数字备注避免依赖当前中文输入法的候选词提交行为。
- 本机 Release 副本：`build/macos/LotBillMac.app`（已被 Git 忽略）。完成 ad-hoc 签名校验，尚未进行对外发布签名或公证。
- macOS 14 最低版本实机、Intel Mac、真实 AI 服务及真实账单未在此次验证中覆盖；没有新增自动同步。


## 历史导入与编辑更新（2026-10-03）

- 识别无分类表头的 A/B/C 工作表、纵向合并大类及“第二分类”表头；数字年份工作表自动更新导入年份。二级分类独立保存，新分类在预览中明确提示。
- 历史导入 → 查看与编辑历史账单，可修改金额、分类和覆盖日期；保留导入来源和编辑前后快照，重算统计并使相关对账待核对。
- 用户提供的工作簿六张年度表在独立测试账本中全部通过导入与总额校验；未写入正式账本，未将原文件复制进仓库。
- 业务回归、Mac 构建及 iOS Simulator 构建通过。Mac 自动 UI 测试因自动化服务初始化超时未执行；已用独立合成账本手动验证二级分类预览、确认导入、历史编辑和保存后金额显示。


## 月份快捷选择（2026-10-03）

点击概览、流水、统计、对账和 AI 月报中的年月按钮会弹出月份选择器。年份可直接输入（1900–2100）或按年调整，12 个月一屏选择，并提供“回到本月”。左右箭头仍可切换相邻月份。Mac Release 和 iOS Simulator 构建通过；已在 Mac 界面验证从 2026-10 直接跳至 2021-02，以及一键返回本月。

年度统计模式下，中间仅显示年份，左右箭头按年切换；点击年份打开独立年份选择，支持直接输入并确认或回到今年。月度模式仍按月切换。Mac Release 与 iOS Simulator 构建通过，已验证年度标题、年份弹窗和切换后全年统计范围。


## 统计导出（2026-10-03）

统计页右上角“导出统计”按当前月份或年份导出。Excel（.xlsx）包含收支汇总、一级分类、二级分类三张表，使用数值金额、两位小数、中文表头和冻结首行。CSV（UTF-8 BOM）使用统一列结构，适合其他表格软件读取。导出使用页面相同的统计计算，包含退款及有效调整；未拆分历史仍明确标注为已知、不完整数据。分类展开列表只显示名称和金额，不再显示每条日期、源文件。原始来源保留在历史账单及导入批次页面。

已通过导出业务测试、Mac Release 和 iOS Simulator 构建；已在 Mac 实际完成 Excel 保存，并用独立读取工具核对三张表合计、数值单元格及格式。

## 记账弹窗性能与布局（2026-10-03）

- 修复输入刷新时反复嵌套扫描分类的问题：分类可选性使用集合查询，分类、账户与退款来源转换为值快照，仅在业务数据版本、记账类型或退款来源变化时刷新；普通收支不预加载退款列表。
- Mac 记账弹窗使用紧凑的列式表单，底部固定取消、保存、保存并继续；金额默认获得焦点，Mac 不再显示手机端的“完成金额输入”按钮。额外模板、退款说明等内容仍可滚动。
- 73 项共享业务测试、3 项 Mac UI 测试通过，涵盖连续输入和保存、搜索及重启持久化、Esc 取消和设置入口。533 个合成分类的选项快照准备耗时约 3.2 ms（本机 Debug 单次结果，不代表端到端输入延迟）；新增停用分类/账户、标签更新与大分类库回归检查。
- Mac Debug、Release 和 iOS Simulator 构建通过；实际窗口核对普通记账字段与固定操作栏可见。本机 Release 副本仍位于 `build/macos/LotBillMac.app`。

## 应用图标与安装包（2026-10-03）

Mac 应用新增墨绿色账本、金色勾选图标，使用独立 `MacAssets.xcassets` 提供 16–1024 像素的标准图标，Xcode 编译生成 AppIcon.icns。源图及完整生成提示词见 [图标设计记录](app-icon.md)。

运行 `bash scripts/package-macos.sh` 可重新构建 Release 并生成：

- `build/macos/LotBillMac.app`：本机应用。
- `build/macos/Lot-Bill.dmg`：带 Applications 快捷方式的拖放安装镜像。

本次 Release 构建、图标资源嵌入、ad-hoc 签名检查和 DMG 校验通过；二进制包含 arm64 与 x86_64。仍为本机开发签名，未进行 Developer ID 签名或公证。本轮新版启动被自动审批拦截，尚未完成打包后的启动验证。
