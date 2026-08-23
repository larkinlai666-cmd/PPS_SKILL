# pps-1.1-software-standard

这是一个采用 `PPS/1.1` 协议维护的个人项目，模式为 `software`。

## 当前入口

- 实时状态：`PROJECT_STATE.md`
- 当前上下文：`CONTEXT.md`
- 生效权威：`DECISIONS.md`
- 当前项目真相：`.`
- 项目导航：`PROJECT_MAP.md`
- 环境清单：`ENVIRONMENT.md`
- 资产清单：`ASSETS.md`（出现外置或受治理二进制资产时创建）
- 当前覆盖证明：`CONTEXT.md`

## 目录

- `docs/`：现行主稿及文档产物
- `assets/`：适合 Git 同步的轻量素材
- `local-assets/`：被 Git 忽略的外置素材物化目录；身份、优先级和哈希写入 `ASSETS.md`
- `prototypes/`：HTML 或其他可预览原型
- `scripts/`：项目本地状态、恢复、环境检查、验证与提交检查脚本

## 恢复工作

Windows：

```powershell
powershell -ExecutionPolicy Bypass -File scripts/resume_packet.ps1
```

macOS / Linux：

```bash
bash scripts/resume_packet.sh
```

恢复包只输出热状态、当前工作集、相关权威与组件导航，不读取目标源码正文。随后只按精确 ID、组件和 Read/Write 路径定向检索；不要靠聊天记忆、全仓库扫描或最近文件猜测状态。

恢复包分别报告 Git 状态与资产物化状态。`core` 和当前 `supporting` 资产缺失时，不能把“Git 已同步”表述为“项目已完整同步”；`reference` 可只保留标记。

## 人话操作

- “同步并继续”：检查本地改动与远端差异，安全同步后恢复当前工作集。
- “保存并同步”：完成当前写入集、验证、提交、对齐远端并推送。
- “这个定了”：把用户明确批准的内容记录为 `D-*`，更新主稿、active block、上下文和覆盖。
- “冷启动接入项目”：检查环境、配置 Git/GitHub、克隆仓库并从有界恢复包恢复，不从聊天记忆重建。

## 收口规则

一次只推进一个当前包。收口时同步更新真实产物、生效权威、项目地图、上下文、资产清单、覆盖表和下一动作，并运行结构验证、完整资产交接检查及 Workset Manifest 声明的项目检查。声明检查通过后运行 `scripts/readiness_check.* --verified` 或 `-Verified`。
