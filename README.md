# PPS Skill

> Proposal Project State：面向长期方案型项目的上下文恢复、历史决策检索、证据追踪与约束覆盖协议。

[![Validate](https://github.com/larkinlai666-cmd/PPS_SKILL/actions/workflows/validate.yml/badge.svg)](https://github.com/larkinlai666-cmd/PPS_SKILL/actions/workflows/validate.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-0.1.0-blue.svg)](CHANGELOG.md)

PPS 适用于世界观、产品方案、品牌与命名、研究报告、战略设计等需要长时间迭代、用户审批和跨设备接续的项目。它把 Git/Markdown 的透明性、全局稳定决策 ID、显式工作集和确定性覆盖校验组合在一起，重点防止两类错误：

1. 历史中存在正确决定，但当前 Agent 没有检索到；
2. Agent 检索到了决定，但没有把它传播到最终成品。

English summary: PPS is a Markdown-and-Git protocol for long-lived proposal projects. It provides durable context recovery, globally stable authority IDs, explicit workset manifests, evidence routing, and fail-loud decision coverage.

## 核心模型

| 层 | 权威内容 |
|---|---|
| 当前成品 | `PROJECT_STATE.md` 指定的主稿 |
| 工作流位置 | `PROJECT_STATE.md` |
| 生效权威 | `DECISIONS.md` 的 active block |
| 当前工作集 | `CONTEXT.md` 的 Workset Manifest |
| 外部证据 | `SOURCE_INDEX.md` 与原始资料 |
| 传播证明 | 当前 coverage artifact |
| 可恢复历史 | Git |

PPS 使用全项目唯一 ID：

- `M-*`：方法与治理约束；
- `F-*`：用户或权威来源提供的事实；
- `P-*`：Agent 提案，不自动生效；
- `H-*`：可逆局部假设，不进入权威索引；
- `D-*`：用户明确批准的决定。

当前包清单中的每个 `M/F/D` 必须同时满足：

- 位于 active authority；
- 存在唯一的 `[active]` 规范记录；
- 出现在当前约束覆盖表；
- 语义上已经传播到真实成品章节。

## 与 GSD 的边界

GSD 更适合以代码、测试和可并行执行计划为主的软件交付。PPS 更适合以用户审批、语义一致性和长期决策正确召回为主的方案交付。

混合项目可以让 PPS 管理产品事实和批准决策，让软件执行系统管理实现；实现需求通过稳定的 `D-*` ID 引用 PPS 权威。

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

安装后，在新任务中使用：

```text
使用 $pps-skill 发起一个 evidence profile 的长期方案项目。
```

## 初始化项目

PowerShell：

```powershell
powershell -ExecutionPolicy Bypass -File `
  "$env:USERPROFILE\.codex\skills\pps-skill\scripts\init_project.ps1" `
  -ProjectName my-plan -Profile standard -ParentDir C:\Projects
```

Bash：

```bash
bash ~/.codex/skills/pps-skill/scripts/init_project.sh \
  my-plan --profile standard --parent ~/Projects
```

两种 profile：

- `standard`：普通长期方案、世界观、产品设计和命名项目；
- `evidence`：增加来源路由和对象×流程覆盖矩阵，适合研究、审计和强证据项目。

## 仓库结构

```text
skills/pps-skill/       可安装的 Codex Skill
tools/                  分发结构校验
tests/                  Windows / Bash 冒烟与失败注入测试
.github/workflows/      CI 与 tag release
```

Skill 的运行入口是 [`skills/pps-skill/SKILL.md`](skills/pps-skill/SKILL.md)。详细协议和设计取舍位于 [`references/`](skills/pps-skill/references/)。

## 开发与验证

```bash
python tools/validate_skill.py
bash tests/smoke.sh
```

Windows：

```powershell
python tools/validate_skill.py
powershell -ExecutionPolicy Bypass -File tests/smoke.ps1
```

贡献前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。版本策略和后续方向见 [CHANGELOG.md](CHANGELOG.md) 与 [ROADMAP.md](ROADMAP.md)。

## 项目声明

PPS Skill 是独立社区项目，不代表 OpenAI，也不隶属于 open-gsd/gsd-core。GSD 只作为工作流设计研究与思想来源之一。

## License

[MIT](LICENSE)
