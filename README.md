# PPS Skill

> Personal Project State：个人 AI 项目的有界上下文、稳定权威、组件导航、分级资产同步、环境冷启动与跨端恢复协议。

[![Validate](https://github.com/larkinlai666-cmd/PPS_SKILL/actions/workflows/validate.yml/badge.svg)](https://github.com/larkinlai666-cmd/PPS_SKILL/actions/workflows/validate.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-0.6.0-blue.svg)](CHANGELOG.md)

PPS 面向一个人使用不同设备或 AI Agent 串行推进的长期项目。它既能管理方案、报告和研究，也能管理轻量网页、小游戏、脚本、工具、原型及文档与代码并重的项目。

PPS 不把整个项目塞回上下文。它通过稳定组件 ID、精确读写路径和有界恢复包，重点抑制五类高成本错误：

1. 忘记仍然生效的事实或决定；
2. 把已经否决或被取代的内容重新引入；
3. 检索到了约束，却没有传播到真实成品；
4. 为恢复进度而重读整个大型代码库；
5. 长会话中目标悄悄漂移：`session_begin` 把目标段哈希锚定在 `.pps/objective-anchor`，verify gate 每次重读目标、红线与生效决策，目标被改写而无 `objective-revised` 事件时拒绝盖戳。

本仓库的自动测试用一个 200,001 行源文件验证：恢复包保持在 240 行和 32768 字节以内，并且不会泄漏未声明的源内容。这证明的是恢复成本有界，不是声称 PPS 能自动理解任意大型代码库。

English summary: PPS is a Markdown-and-Git protocol for long-lived personal document, software, and hybrid projects. It provides bounded recovery, globally stable authority and component IDs, exact read/write worksets, environment checks, and fail-loud validation.

## 核心模型

| 层 | 权威内容 |
|---|---|
| 当前内容入口 | `PROJECT_STATE.md` 的 `Main` |
| 工作流位置 | `PROJECT_STATE.md` |
| 生效权威 | `DECISIONS.md` 的 active block |
| 事件编年 | `EVENTS.md`（固定格式，追加脚本，月度归档） |
| 架构导航 | `PROJECT_MAP.md` 的稳定 `C-*` 组件 |
| 当前工作集 | `CONTEXT.md` 的 ID、组件、Read/Write/Verify |
| 任务登记（可选） | `TASK_INDEX.md` 的 `T-*`、writer lease 与 `MERGES.md` 类型化合并回执 |
| 资产身份 | 可选 `ASSETS.md` 的 `A-*` 优先级、同步后端、大小与哈希 |
| 设备物化 | Git/LFS/云端取得的本地字节；与 Git 同步状态分开 |
| 验证证据 | 设备本地 `.pps/verify-stamp`（verify gate 写入，readiness 校验） |
| 环境需求 | `ENVIRONMENT.md` |
| 外部证据 | `SOURCE_INDEX.md` 与原始资料（evidence profile） |
| 传播证明 | 当前 coverage artifact（证据列必填） |
| 可恢复历史 | Git |

权威 ID 全项目唯一：

- `M-*`：方法与治理约束；
- `F-*`：用户或权威来源提供的事实；
- `P-*`：Agent 提案，带 opened 日期，挂起超 7 天必须重述处置；
- `H-*`：可逆局部假设，不进入权威索引；
- `D-*`：用户明确批准的决定；
- `C-*`：稳定组件边界，不等同于逐文件清单；
- `A-*`：稳定资产身份；区分核心、当前支撑与非阻断参考素材；
- `T-*`（可选多任务层）：稳定任务身份；唯一 active integrator 持有 Canonical 写权。

PPS/1.2 来自两个真实项目战役的蒸馏：多 Agent 接力项目贡献了接力保护（开工 `git status`、禁覆写脏文件、显式交接）、verify gate 执行证据、事件编年、覆盖证据列与红线协议位；单所有者多任务项目贡献了任务登记、writer lease、类型化合并回执与越界写入门禁。PPS/1.0 与 1.1 项目继续原样通过验证。

当前包中的每个 `M/F/D` 必须处于 active 状态、存在唯一规范记录并具有覆盖行。每个 `C-*` 必须解析到唯一组件行。Read/Write 合计目标不超过 12 个路径，硬上限为 30；仓库根 `.` 和 glob 不是合法工作集路径。

大型素材采用分级同步：`core` 必须通过 Git、Git LFS 或持久云端完整同步；`supporting` 仅在当前包引用时要求物化；`reference` 可以不跨设备复制，但必须保留标记且不能作为当前包的隐式事实。云端定位符统一为无凭据的 `rclone:REMOTE:path`，完整交接会检查远端对象存在且字节数一致。Git clean/push 不能替代资产完整性结论。

## 模式、Profile 与边界

三种项目模式：

- `document`：主真相是方案、报告、设定或研究文档；
- `software`：轻量网页、小游戏、脚本、工具、原型或既有代码库；
- `hybrid`：维护中的规格文档和可执行产物同等重要。

两种 profile：

- `standard`：普通个人项目；
- `evidence`：增加来源路由与显式证据覆盖。

PPS 只适配个人串行推进。它不提供多人权限、任务分派、分布式锁、团队队列或合并所有权，也不替代项目自己的构建、测试、预览和发布工具。

## 安装

通过 Codex 的 `skill-installer` 安装本仓库中的 `skills/pps-skill`：

```text
请使用 skill-installer 安装：
https://github.com/larkinlai666-cmd/PPS_SKILL
子目录：skills/pps-skill
```

也可以手动复制：

```powershell
git clone https://github.com/larkinlai666-cmd/PPS_SKILL.git
Copy-Item -Recurse .\PPS_SKILL\skills\pps-skill "$env:USERPROFILE\.codex\skills\"
```

安装后可这样触发：

```text
使用 $pps-skill 发起一个 software 模式的个人小游戏项目。
```

先运行已安装 Skill 的健康检查：

```bash
bash ~/.codex/skills/pps-skill/scripts/validate_skill.sh
```

```powershell
powershell -ExecutionPolicy Bypass -File `
  "$env:USERPROFILE\.codex\skills\pps-skill\scripts\validate_skill.ps1"
```

## 初始化与恢复

PowerShell：

```powershell
powershell -ExecutionPolicy Bypass -File `
  "$env:USERPROFILE\.codex\skills\pps-skill\scripts\init_project.ps1" `
  -ProjectName my-game -Mode software -Profile standard -ParentDir C:\Projects
```

Bash：

```bash
bash ~/.codex/skills/pps-skill/scripts/init_project.sh \
  my-game --mode software --profile standard --parent ~/Projects
```

默认模式仍为 `document`。现有非空项目必须先审计，不能直接初始化。

每次换设备或 Agent 后，先生成恢复包：

```bash
bash scripts/resume_packet.sh .
```

```powershell
powershell -ExecutionPolicy Bypass -File scripts/resume_packet.ps1 -Root .
```

恢复包只包含热状态、当前包、工作集、相关组件行、权威标题和 Git 风险，不包含源文件正文。

若项目包含受治理资产，恢复包还会执行快速存在性/大小检查。收口和交接使用完整 SHA-256 与二进制风险检查：

```bash
bash scripts/asset_check.sh . --handoff --risk
# 在人工检查并执行 ENVIRONMENT/CONTEXT 声明的 Verify 后：
bash scripts/readiness_check.sh . --verified
```

## 环境冷启动

项目声明最小环境后，医生默认只检查：

```bash
bash scripts/environment_doctor.sh .
```

```powershell
powershell -ExecutionPolicy Bypass -File scripts/environment_doctor.ps1 -Root .
```

新设备尚未 clone 时，从已安装 Skill 运行 `environment_doctor.sh --core` 或 `environment_doctor.ps1 -Core`，先检查 Git 与 GitHub CLI；这个入口不依赖项目清单。

可预览缺失必需工具的安装计划。系统安装必须同时传入 `--apply --yes` 或 `-Apply -Yes`。PPS 不会隐式安装包管理器、修改 shell 配置、执行 `curl | shell`、安装全局语言包或启动守护进程；可选工具也不会被自动安装。

## 审计既有项目

迁移前先生成只读报告：

```bash
bash skills/pps-skill/scripts/audit_legacy_project.sh \
  --root /path/to/existing-project
```

```powershell
powershell -ExecutionPolicy Bypass -File `
  skills/pps-skill/scripts/audit_legacy_project.ps1 `
  -Root C:\path\to\existing-project
```

审计会识别 PPS/1.0、PPS/1.1、旧版 `plan-project-sync`、其他结构化状态系统、混合状态或无结构项目，并给出 provisional mode/profile、严格 ID 数、自由决策段、机器配置污染、依赖清单、实现代码和二进制资产信号。生成目录与依赖缓存会被排除，避免 `node_modules` 等内容制造模式误判或无界扫描。报告只能写到目标项目之外，避免审计本身制造第二套状态。

## 开发与验证

```bash
python3 tools/validate_skill.py
bash tests/smoke.sh
bash skills/pps-skill/scripts/validate_skill.sh
```

```powershell
python tools/validate_skill.py
powershell -ExecutionPolicy Bypass -File tests/smoke.ps1
powershell -ExecutionPolicy Bypass -File `
  skills/pps-skill/scripts/validate_skill.ps1
```

CI 在 Linux、macOS 和 Windows 上运行相关套件。旧版能力对照见 [COMPATIBILITY.md](COMPATIBILITY.md)，本轮第一性原则审查见 [ADVERSARIAL_REVIEW.md](ADVERSARIAL_REVIEW.md)，后续方向见 [ROADMAP.md](ROADMAP.md)。

## 项目声明

PPS Skill 是独立社区项目，不代表 OpenAI。其运行时不依赖其他状态管理流程、线上模板或托管状态服务。

## License

[MIT](LICENSE)
