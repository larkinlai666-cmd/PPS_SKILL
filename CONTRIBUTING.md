# Contributing

感谢你帮助改进 PPS。这个项目优先保护协议的可解释性、向后兼容性和校验可信度。

## 提交改动前

1. 对行为变化先创建 Issue，说明真实使用场景和失败模式。
2. 保持 `skills/pps-skill/` 为可直接安装的独立技能，不在其中加入仓库级 README、CHANGELOG 或开发文档。
3. 协议语法变化必须说明迁移方式；不得让旧项目静默改变语义。
4. 校验器不得为了让错误状态通过而降低门槛。
5. 不引入向量库、数据库、常驻服务等强依赖，除非已有明确用例和维护方案。

## 本地验证

至少运行：

```bash
python3 tools/validate_skill.py
bash tests/smoke.sh
```

涉及 PowerShell 时再运行：

```powershell
python tools/validate_skill.py
powershell -ExecutionPolicy Bypass -File tests/smoke.ps1
```

新增或修复校验规则时，应同时提交：

- 一个能够通过的正向样例；
- 一个此前会被错误接受的失败注入样例；
- Windows 与 Bash 行为一致性说明。

## Pull Request

PR 描述应包含：

- 改了什么；
- 为什么需要；
- 对现有项目的兼容影响；
- 验证命令和结果；
- 如果改变协议，迁移步骤是什么。

建议使用简短的 Conventional Commit 前缀：

- `feat:` 新能力；
- `fix:` 缺陷修复；
- `docs:` 仓库级文档；
- `test:` 测试；
- `refactor:` 不改变外部语义的重构；
- `chore:` 维护工作。

## 版本策略

项目遵循 Semantic Versioning：

- Patch：兼容的修复、文档与校验增强；
- Minor：向后兼容的新 profile、字段或工具；
- Major：协议语义、必需文件或解析规则的不兼容变化。
