---
title: WorkerEnv 管理
description: WorkerEnv 的任务导向运维视角——添加、列出、挂载、摘下、轮换、解密 worker 的 shell 环境变量。
section: User guide
order: 60
---

WorkerEnv 是 worker 在回合开始时读取的加密 shell 环境存储。本页是管理它的任务导向运维视角——路由、scope、轮换纪律、解密权限。它以具体操作补充 [WorkerEnv secret](../worker-env/) 概念页。

先把决定性的性质说清楚：改动在**下一个回合**生效，不在已运行的回合上。保存的 secret 在 worker 下一个回合到达；进行中的回合保留它启动时的环境。

## 列出和读取

```bash
curl https://ankole.example.com/api/v1/worker-envs \
  -H "Authorization: Bearer $CONSOLE_TOKEN"

curl https://ankole.example.com/api/v1/worker-envs/MY_API_KEY \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

`GET /worker-envs` 列出全局条目。`GET /worker-envs/:name` 读取一个。列出和读取返回元数据，不是 secret 值——`secret` 标志告诉你值是否加密。

## 添加或更新全局变量

```bash
curl -X PUT https://ankole.example.com/api/v1/worker-envs/MY_API_KEY \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "value": "sk-...", "secret": true }'
```

`PUT /worker-envs/:name` 创建或更新一个全局变量。`secret` 标志控制值是否静态加密——敏感的东西设它。

## 把变量挂到一个 agent

```bash
curl -X PUT https://ankole.example.com/api/v1/agents/<agent_uid>/worker-envs/MY_API_KEY \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "value": "sk-...", "secret": true }'
```

按 agent 的变量覆盖该 agent 的全局值。用 `GET /agents/:agent_uid/worker-envs` 列出 agent 的有效变量——响应含来源（每个变量来自哪条轨道）。

## 从 agent 摘下变量

```bash
curl -X DELETE https://ankole.example.com/api/v1/agents/<agent_uid>/worker-envs/MY_API_KEY \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

摘下移除按 agent 的覆盖；全局值（若有）在下次回合重新生效。

## 轮换 secret

轮换是解密的安全替代。通过 `PUT` 设新值；旧值被覆盖。新值在 worker 下一个回合到达。不要为"检查"而解密旧值——设新值并继续。

## 解密（少用）

```bash
curl -X POST https://ankole.example.com/api/v1/worker-envs/MY_API_KEY/decryptions \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

`POST .../decryptions` 揭示存储的值。它是一项单独授权的动作——`decrypt` 权限，与 `read` 分开。仅在你确实需要看存储值（调试、脚本化轮换前确认）时用。每次解密可观测。

## 合并顺序

一个 agent 的有效环境是合并，从最低到最高优先级：

1. 已声明变量（带 `worker_env_name` 的 AppConfigure）
2. 全局自定义变量
3. 按 agent 自定义变量
4. 绑定派生变量（来自已激活 adapter）
5. 模型对单条命令显式给出的 `env`

Provider 派生的身份覆盖运维者行；受信任的模型对单条命令有最终决定权。

## 保留名

一些名字无法通过 WorkerEnv 设置：`PATH`、`HOME`、`SHELL`、`TERM`、`LANG`、`BASH_ENV`、`ENV`、`WORKER_ID`、`RUNTIME_FABRIC_URL`、`DATABASE_URL`、`CODEX_UNSAFE_ALLOW_NO_SANDBOX`，以及任何以 `ANKOLE_` 开头的。存储拒绝它们——这些名字由 sandbox 或 worker 身份拥有。

## 本指南不是什么

它不是 WorkerEnv 概念页——三轨道合并模型、加密细节、与 AppConfigure 的区别见 [WorkerEnv secret](../worker-env/)。它不是 AppConfigure 指南——非 shell 变量的运维者管理设置见 [AppConfigure](../app-configuration/)。它不是安全加固指南——轮换与解密纪律见[安全加固](../security-hardening/)。

## 下一步

- 概念页，读 [WorkerEnv secret](../worker-env/)。
- AppConfigure（另一个存储），读 [AppConfigure](../app-configuration/)。
- 安全姿态，读[安全加固](../security-hardening/)。
- Console 路由，读 [Console API 参考](../console-api/)。
