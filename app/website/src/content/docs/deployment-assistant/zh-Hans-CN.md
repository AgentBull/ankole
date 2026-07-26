---
title: 部署助手
description: 如何设置一个辅助部署的 agent——跑部署前检查、应用部署、验证健康、冒烟测试失败则回滚。
section: Guides
order: 353
---

一个部署助手 agent 跑部署前检查清单、应用部署、验证服务健康、冒烟测试失败则回滚到上一个已知良好状态。本指南是那个 agent 的实际形态。它与[升级](../updating/)指南（覆盖运维者的手动部署流程）紧密相关——本页覆盖辅助或自动化该流程的 agent。

先把决定性的性质说清楚：agent **部署和验证，失败则回滚**。它应用变更、检查健康、冒烟测试失败就恢复上一个已知良好状态。价值在于验证循环——在用户之前抓到坏部署——不在于部署速度。

## 需要什么

- **WorkerEnv 里的 git 凭证**（`GIT_TOKEN`）——若部署涉及拉代码。
- **绑定 `primary` profile**——agent 读健康检查输出并决定通过/失败。
- **一个 signal binding** 到部署状态发帖的频道。
- **部署访问**——agent 需要 shell 访问部署命令（`docker compose`、`helm`、`kubectl`、或 CI 的部署触发器）。
- **一个冒烟测试**——部署后 agent 发送的、验证服务工作的请求。

## 工作流

1. **部署请求到达**——"把 `release-v2` 分支部署到 staging"、或 CI 的 webhook。
2. **agent 跑预检**——确认分支构建、测试通过、镜像可用。
3. **agent 应用部署**——`docker compose pull && docker compose up -d --force-recreate`、或 `helm upgrade`、或 CI 触发。
4. **agent 等待健康**——轮询健康端点直到返回健康，带超时。
5. **agent 跑冒烟测试**——向已知端点发请求并检查响应。
6. **通过 → 报告成功。失败 → 回滚**——冒烟测试失败则 agent 恢复上一个镜像/tag 并报告失败及冒烟测试证据。

## 人设控制什么

- **预检**——"确认 `bun test` 通过、Docker 镜像在 registry 里、数据库备份已做。"
- **部署命令**——你的部署目标的确切命令。
- **健康检查**——"每 5 秒轮询 `GET /health` 共 60 秒。健康 = 200 OK。"
- **冒烟测试**——"发 `GET /api/v1/status` 并检查 `{"status":"ok"}`。"
- **回滚**——"冒烟测试失败时用上一个镜像 tag 跑 `docker compose down && docker compose up -d`。报告失败。"
- **不做什么**——"不经明确人批准不部署到生产。不跳过数据库备份。"

## 回滚纪律

回滚是安全网。人设必须执行：

- **冒烟测试失败时自动回滚**——agent 不等人决定；立即恢复并报告。
- **回滚到上一个已知良好状态**——上一个镜像 tag，不是猜测。agent 部署前记录当前 tag 以便能恢复。
- **数据库 migration 不可逆**——agent 能回滚镜像，但部署包含 migration 时报告"镜像已回滚，但 migration X 已应用且不可逆。需人工介入。"

## 一个完整示例

为 Docker Compose 部署设置部署助手：

1. 创建 agent，绑 `primary`/`coding`。
2. 撰写 `MISSION.md`："收到部署请求时：跑 `bun test`。通过则记录当前镜像 tag、`docker compose pull && docker compose up -d --force-recreate`。轮询 `/health` 60 秒。向 `/api/v1/status` 发冒烟测试。冒烟测试失败则恢复上一个 tag、`docker compose up -d`。报告结果。不跳过备份。"
3. 在频道里："把 release-v2 部署到 staging。"
4. agent 测试、记录、部署、健康检查、冒烟测试、报告（或回滚）。

## 本指南不是什么

它不是 CI/CD 管线——agent 辅助一次特定部署，由人或 webhook 触发；它不替代你的管线。它不是蓝绿部署工具——agent 做顺序部署+验证，非并行环境切换。它也不是[升级](../updating/)指南的替代——那页覆盖运维者的手动流程；本页覆盖辅助的 agent。

## 下一步

- 手动部署流程，读[升级](../updating/)。
- 回滚机制（镜像+migration），读[升级](../updating/)和[备份与还原](../backup-and-restore/)。
- shell 工具（部署命令），读[代码执行](../code-execution/)。
- 事故响应（失败部署后发生什么），读[事故响应](../incident-response/)。
