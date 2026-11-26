<div align="right">

[English](README.md) | **简体中文**

</div>

# NeoLinker

[![CI](https://github.com/camthink-ai/NeoLinker/actions/workflows/ci.yml/badge.svg)](https://github.com/camthink-ai/NeoLinker/actions/workflows/ci.yml)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg?logo=apache)](LICENSE)

NeoLinker 是面向 **CamThink NE 系列低功耗 AI 相机**的 Windows 桌面配置工具：
通过蓝牙（BLE）、设备 softAP 或局域网发现设备，完成连接 → 配置 → 校验的
完整配置流程，并为每台设备生成可留存的纯文本回执。界面中英双语、亮暗双主题。

## 功能

- **环境自检**——启动时逐路检查 BLE 适配器 / WLAN / LAN 的可用性。
- **三路发现**——BLE 广播扫描、softAP SSID 扫描、局域网发现（CT-Disc）；
  支持机型过滤、分页，以及扫码录入（扫描或上传设备二维码图片）。
- **相位驱动的配置会话**——连接 → 读能力 → 逐模块配置 → 下发 → 结果；
  断连自动检测并原位重连，迟到结果幂等丢弃。
- **能力驱动的配置表单**——设备上报自身支持的配置模块（Wi-Fi / 蜂窝 /
  MQTT / webhook …），表单按上报生成并预填当前值。
- **内嵌设备控制台**——NE503 的管理页在应用内（WebView2）直接打开。
- **回执与历史**——每次完成的会话写出按设备的纯文本回执；历史可列表、
  可导出。

## 机型支持

| 机型 | BLE（CT-Prov/1） | SoftAP（CT-Prov over HTTP） | LAN（CT-Disc） | 备注 |
| ---- | :---: | :---: | :---: | ---- |
| NE101 | ✅ | ✅ | — | 主目标机型；BLE 链路已真机端到端验证 |
| NE301 | 🚧 | ✅ | — | 暂只走 softAP，BLE 计划中；通讯模块配置（Wi-Fi / 蜂窝 / MQTT / webhook） |
| NE503 | — | — | ✅ | 发现 + 内嵌管理页；最新、真机暴露最少的一路 |

真机测试目前以 NE101 为主；NE301 暂只支持 softAP 配置（BLE 计划中）；
NE503 支持较新。

## 下载

从 [Releases](https://github.com/camthink-ai/NeoLinker/releases) 下载最新的
`NeoLinker_v*_windows_x64.zip`，解压后直接运行 `NeoLinker.exe`，无需安装。

运行要求：Windows 10/11 x64、WebView2 Evergreen 运行时（Win11 及多数已更新
的 Win10 自带）、BLE 通道需要蓝牙适配器。

## 从源码构建

前置条件：

- Windows 10/11 x64
- Flutter 3.47.8（钉版——更新的 stable 会因本仓库尚未迁移的弃用 info 使
  `flutter analyze` 失败，见 [ci.yml](.github/workflows/ci.yml)）
- Visual Studio 2022 Build Tools（*使用 C++ 的桌面开发* 工作负载）
- `PATH` 上有 `nuget.exe`（WebView2 插件构建时还原 NuGet 包）

```bash
git clone https://github.com/camthink-ai/NeoLinker.git
cd neolinker/apps/desktop_app
flutter pub get
flutter gen-l10n          # 改 ARB 后重新生成本地化代码
flutter analyze
flutter test
flutter run -d windows    # 或：flutter build windows --release
```

CI 在每次 push 对所有包跑 analyze + test；Windows release 构建仅在
`v*` 标签与手动触发时执行。入口 [tool/ci.sh](tool/ci.sh)。

## 仓库结构

```text
neolinker/
├── apps/desktop_app/          # Windows 应用（Flutter）
├── packages/
│   ├── neolinker_ui/          # 设计系统（OKLCH 令牌 + 基础组件）
│   ├── ct_prov_core/          # CT-Prov/1 协议核心（分片/信封/错误码）
│   ├── test_vectors/          # CT-Prov/1 黄金向量（广播/分片/信封）
│   ├── discovery_domain/      # 发现领域层（三路通道归一化）
│   ├── provisioning_session/  # 配置会话状态机
│   ├── communication_domain/  # 通讯配置 schema 与校验
│   ├── ble_universal/         # universal_ble 具体适配（扫描桥 + GATT 通道）
│   ├── ble_adapter/           # CT-Prov BLE 适配层（广播解析 + GATT 传输）
│   ├── softap_transport/      # CT-Prov over softAP HTTP（会话语义同 BLE）
│   ├── ap_discovery_adapter/  # softAP 发现适配（Windows WLAN SSID 扫描）
│   └── ct_disc_adapter/       # CT-Disc 局域网发现适配（组播 announce 监听）
├── design/                    # 品牌标（链·N）：SVG 母版 + PNG 导出
└── tool/                      # CI 入口、设计令牌与应用图标生成脚本
```

## 文档

本应用实现的线上协议规范发布在 [`docs/`](docs/)（英文）：

- [CT-Prov/1 通讯配置协议](docs/ct-prov-protocol.md)（BLE GATT + softAP HTTP 绑定）
- [CT-Prov/1 配置模式](docs/ct-config-schema.md)（`config.set` 各配置节字段）
- [CT-Disc 设备发现与管理协议](docs/ct-disc-protocol.md)（UDP 组播 + MQTT）

## 工程注记（中文维护者向）

### 中英双语（i18n）

- 方案：Flutter 官方 `gen-l10n`（ARB 文件 + 代码生成），zh 为模板语言，
  en 为第二语言。
- 文案位置：`apps/desktop_app/lib/l10n/app_*.arb`；查表扩展
  `lib/l10n/labels.dart`。
- 规则：**neolinker_ui 组件不硬编码文案**（label 一律由应用层传入并本地化）；
  新增语言 = 新增一个 ARB 文件。
- 语言与主题同为工具设置项（持久化）。
- 本地改词后必须 `flutter gen-l10n`（产物 `lib/l10n/app_localizations*.dart`
  已 gitignore；CI 自动执行，本地 analyze 前记得手动跑）。

### 设计令牌

`packages/neolinker_ui/lib/src/tokens.dart` 由 `tool/gen_tokens.py` 生成
（OKLCH 令牌，亮/暗两套，经 `ThemeExtension` 注册）；Widget 内用
`context.nl.background` 等访问，**勿手改生成文件**，改设计先改原型再重新生成。

### 品牌标（链·N）

- 母版 `design/logo.svg`（单墨 currentColor，随语境着色）；`design/logo-tile.svg`
  （App 图标基形）。概念稿见 `design/logo-concepts.html`。
- App 图标与 PNG 由 `tool/gen_app_icon.py` 生成（16–256 多尺寸；≤24px 用
  简化形）。
- UI 内一律用 `NLLogo` 组件，不贴图；改几何时同步母版 / 组件 / 生成脚本
  三处（同为 0..96 坐标空间）。

## 参与

见 [CONTRIBUTING.md](CONTRIBUTING.md)。本项目遵循
[贡献者公约](CODE_OF_CONDUCT.md)；安全问题请走 [SECURITY.md](SECURITY.md)
的私密渠道，勿开公开 issue。

## 许可

Apache-2.0，见 [LICENSE](LICENSE)。Copyright 2026 CamThink Team.
