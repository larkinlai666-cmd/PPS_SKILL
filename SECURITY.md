# Security Policy

## Supported versions

当前仅维护最新发布版本。

## Reporting a vulnerability

请优先通过本仓库的 GitHub Security Advisory 私密报告漏洞。不要在公开 Issue 中提交令牌、私人仓库地址、用户文件内容或可直接利用的安全细节。

如果私密报告入口暂不可用，可以创建一个不包含漏洞细节的 Issue，请求维护者建立私密沟通渠道。

## Security boundaries

PPS 的脚本默认只操作用户明确指定的新项目目录，并拒绝非空初始化目标。贡献不得：

- 静默上传项目内容；
- 持久化访问令牌；
- 覆盖未确认的现有目录；
- 修改全局 Git 身份或系统 PATH；
- 将外部来源内容自动提升为生效决策。
