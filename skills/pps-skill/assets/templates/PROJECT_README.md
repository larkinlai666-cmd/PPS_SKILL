# {{PROJECT_NAME}}

这是一个采用 `PPS/1.0` 协议维护的方案型项目。

## 当前入口

- 实时状态：`PROJECT_STATE.md`
- 当前上下文：`CONTEXT.md`
- 生效权威：`DECISIONS.md`
- 现行主稿：`{{MAIN_ARTIFACT}}`
- 当前覆盖证明：`{{COVERAGE_ARTIFACT}}`

## 恢复工作

Windows：

```powershell
powershell -ExecutionPolicy Bypass -File scripts/status_check.ps1
```

macOS / Linux：

```bash
bash scripts/status_check.sh
```

按状态输出读取 `CONTEXT.md` 的 Workset Manifest，再按精确 ID 定向读取 `DECISIONS.md`。不要靠聊天记忆或最近文件猜测生效决策。

## 收口规则

一次只推进一个当前包。用户批准或修改后，同一写入批次更新主稿、生效权威、上下文、覆盖表和下一动作，并运行 `scripts/validate_project.*`。
