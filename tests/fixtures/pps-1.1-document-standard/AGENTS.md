# AGENTS.md — PPS/1.1 个人项目接手协议

项目终点是当前个人项目产物可验证地完成，不是建设长期知识库或多人协作平台。

## L0 恢复

1. Windows 运行 `powershell -ExecutionPolicy Bypass -File scripts/resume_packet.ps1`；其他系统运行 `bash scripts/resume_packet.sh`。
2. 读取 `PROJECT_STATE.md` 的 Mode、Stage、Main、Map、Environment、Package、Status、Capsule、Coverage、Blockers、Next。
3. 读取胶囊中的 `Workset Manifest`。
4. 按 `M/F/D` 精确检索权威，按 `C-*` 查项目地图，只读取 `Read` 指向的文件或符号，再编辑 `Write` 范围。
5. 解析 `Assets` 中的 `A-*`；快速检查全部核心资产和当前支撑资产，只物化本包需要的内容。
6. 不得把整个仓库、整个源码目录或“最近几个文件”塞进上下文替代显式清单。

## 权威

- `M`：方法与治理约束。
- `F`：用户或权威资料提供的事实，Agent 不得改写。
- `P`：Agent 的完整建议，未获批准前不约束后续。
- `H`：可逆、局部、非阻塞的工作假设；注明失效条件。
- `D`：用户明确批准的决定，约束后续。

只有 `M/F/D` 进入 `DECISIONS.md` 的 active block。ID 全项目唯一、稳定；废止时保留记录并改状态，不复用编号。

## 工作边界

- 一次只维护一个当前包。
- 文档先提供真实成品切片；软件先锁定组件、入口、接口、改动路径和验证命令。
- Agent 负责补完 `P`；能用安全 `H` 继续时不阻塞用户。
- 只有缺失外部事实、同级权威冲突，或无安全默认且会改变架构时才提问。
- `CONTEXT.md` 是派生的当前工作集，不是权威正文或历史堆栈。
- `PROJECT_MAP.md` 是稳定导航，不是自动生成的全文件清单；只在架构边界变化时更新。
- 普通恢复只做 L0；来源核验升到 L1；阶段矩阵审计升到 L2；最终全源审计升到 L3。

## 检索与覆盖

- 先查当前清单，再查全局 active authority；时间近不等于权威高。
- 历史候选必须区分 active、superseded、rejected、frozen，不能自动生效。
- 当前清单中的每个 `M/F/D` 都必须出现在覆盖表，并指向真实成品章节。
- 当前 `Components/Read/Write` 必须足以完成当前包，但保持有界；Read/Write 不得使用仓库根或 glob，目录只允许作为精确搜索范围，不允许批量读取所有后代源码。
- 验证器通过只代表结构覆盖；提交评审前仍需检查语义矛盾、遗漏传播和偷偷缩减范围。
- Git 已同步不等于资产已物化。`core` 必须有 Git/LFS/云端副本，当前 `supporting` 必须可取得；`reference` 可只留标记且不得进入当前 Workset。
- 决策形文本解析失败必须修复，不得静默忽略。

## 写入与并发

- 主任务是状态文件、项目地图、当前产物和覆盖表的唯一写入者。
- 并行任务可以查资料或给建议，但只返回结论和精确位置，由主任务串行合并。
- 用户反馈后立即更新主稿；批准项形成 `D`，否决项离开现行主稿，历史交给 Git。
- 每次收口同步更新真实产物、`DECISIONS.md`、`PROJECT_MAP.md`（仅架构变化时）、`CONTEXT.md`、覆盖表和 `PROJECT_STATE.md`。
- 声称完成前运行当前环境/项目 `Verify`，再运行 `scripts/readiness_check.* --verified`/`-Verified`；失败时修复项目，不降低门槛。

## 同步

- Git 是跨设备历史，不替代当前语义权威。
- 不覆盖未提交的用户改动，不强推，不提交无关文件。
- 只有用户要求保存、提交或同步时执行相应 Git 写操作。
- 新设备先运行 `scripts/environment_doctor.*`，再生成恢复包；系统级安装必须获得一次明确授权。
- “同步并继续”：检查 dirty/remote/upstream，安全拉取后按 Workset Manifest 恢复。
- “保存并同步”：完成写入集并验证，检查核心/当前支撑资产的完整交接状态，检查精确 diff，提交、拉取协调并推送；分别报告 Git 与资产同步结果。
- “这个定了”：仅对用户明确批准的内容创建或更新 `D-*`，并完成全写入集传播。
- “冷启动接入项目”：按 Skill 的 `git-sync.md` 先用已安装 Skill 的 core doctor 检查 Git/gh，克隆后运行项目 doctor 与恢复包。

PPS 只适配个人串行推进。未经用户批准，不引入全局语言包、Wiki、向量库、图数据库、RAG、常驻服务、另一套状态系统或多人协作编排。
