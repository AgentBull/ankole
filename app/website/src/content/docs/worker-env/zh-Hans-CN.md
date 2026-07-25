---
title: WorkerEnv secret
description: Agent Computer worker 的加密 shell 环境存储——三条轨道、每个 agent 一份合并后的环境，仅在一次回合的临时 RPC 路径上解密。
section: Operations
order: 17
---

WorkerEnv 是 Agent Computer shell 在跑一个回合时所看到的环境变量存储。运维者在这里把一个 API key 或 token 放一次，挂到合适的范围，worker 在回合开始时收到它——已解密。本页对照 `Ankole.SignalsGateway.ActorRuntime.WorkerEnv` 里的真实代码，画出这套模型。

先把决定性的性质说清楚：secret 值在静态存储时按行派生密钥加密，而那个解密后的扁平 map 唯一存在的地方，是通向 worker 的临时 RPC 路径。没有任何持久的东西存着这份合并后的环境。浏览配置永远看不到 secret；揭示一个 secret 是一项单独的、单独授权的动作。

## 三条轨道，一份合并后的环境

worker 所看到的 shell 环境是三条轨道的合并，理解这次合并就是全部要点：

- **已声明变量（declared）**是带有 `worker_env_name` 标记的 AppConfigure 定义。它们的 schema、加密、描述和按 agent 的覆盖都留在 AppConfigure；WorkerEnv 只把解析后的值投影进 shell。带标记的定义必须在启动时注册，而不是懒注册，否则枚举会漏掉它们。
- **自定义变量（custom）**是 `agent_computer_worker_envs` 里的自由形态运维者行，全局或按 agent，每一行带一个 `secret` 标志。这就是 Console 读写的那张表。
- **绑定派生变量（binding-derived）**由该 agent 已激活的 signal adapter 解析。它们是临时的——永远不会变成可编辑的 Console 行。

合并顺序，从低到高：已声明，然后自定义全局，然后自定义按 agent，然后绑定派生，然后模型对单条命令显式给出的 `env`。provider 派生的身份覆盖运维者行，而受信任的模型仍然对单条命令有最终决定权。一个绑定派生的、属于 agent 真正连接的那个 provider 的 token，会覆盖同名的运维者行——这通常正是你想要的。

## 名字与保留名

一个 WorkerEnv 名字是一个 shell 变量名：必须匹配 `~r/\A[A-Za-z_][A-Za-z0-9_]*\z/`。某些名字被保留，因为 sandbox 引导或 worker 身份拥有它们——`PATH`、`HOME`、`SHELL`、`TERM`、`LANG`、`BASH_ENV`、`ENV`、`WORKER_ID`、`RUNTIME_FABRIC_URL`、`DATABASE_URL`、`CODEX_UNSAFE_ALLOW_NO_SANDBOX`，以及任何以 `ANKOLE_` 开头的名字。从运维者行覆盖这些，并不能限制模型——它可以在 shell 内部重新 export——但会以令人困惑的方式破坏 sandbox 契约，所以存储拒绝它们。

## 加密：每行一把密钥

secret 用 kernel 支持的 AEAD 加密封存。行密钥同时从 scope 和 name 派生，所以一段被复制到另一行的密文无法作为有效值解密。密钥派生域是 `worker_env`，这让这些密文作为 AppConfigure 行不可读，反之亦然——两套存储即便用的是同一个 kernel 原语，也读不了对方的 secret。

按契约，值是纯字符串，因为 shell 变量就是字符串；加密层不做 JSON 往返。一个解析后得到非字符串、非 nil 值的已声明键，被当作声明 bug，会大声失败，而不是把垃圾 export 进 shell。

## 按名路由：一个编辑界面

Console 的读写按名路由，所以即便背后轨道不同，运维者看到的也是一个编辑界面。一个名字先解析到它的自定义行（匹配合并优先级），再解析到它的已声明定义，否则就创建一个自定义行。这就是为什么运维者要改一个变量时，永远不必知道它住在哪条轨道上。

## 路由

Console 界面分成全局和按 agent 两个范围，各自有读、写、删、解密：

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/worker-envs` | 列出全局变量 |
| `GET` | `/worker-envs/:name` | 读取一个全局变量（元数据，不是明文） |
| `PUT` | `/worker-envs/:name` | 创建或更新一个全局变量 |
| `DELETE` | `/worker-envs/:name` | 移除一个全局变量 |
| `POST` | `/worker-envs/:name/decryptions` | 解密一个全局变量 |
| `GET` | `/agents/:agent_uid/worker-envs` | 列出某个 agent 的有效变量及其来源 |
| `PUT` | `/agents/:agent_uid/worker-envs/:name` | 创建或更新一个按 agent 的变量 |
| `DELETE` | `/agents/:agent_uid/worker-envs/:name` | 移除一个按 agent 的变量 |
| `POST` | `/agents/:agent_uid/worker-envs/:name/decryptions` | 解密一个按 agent 的变量 |

列出和读取返回元数据，不是 secret 值。每一个动作都跑在 Console 策略之下——read、update、reset、decrypt 是 `worker_env:<name>` 和 `agent:<uid>:worker_env:<name>` 资源上各自独立的动作。

## 解密是单独的权限

揭示一个加密值是它自己的一项授权动作，和读取该行不同。策略动作是 `worker_env:<name>` 的 `decrypt`，与 `read`、`update` 分开。这是刻意的：一个能浏览配置的运维者，仅凭这一点，看不到 secret 材料。解密一个值是一个可观测的、特权的动作，不是读取列表的副作用。

## 回合注入边界

worker 开始一个回合时，它调用 `worker_env.resolve` 这个 RuntimeFabric RPC。broker 把 agent 解析成一个活跃主体，算出已经把 secret 解密的合并环境，并把它放在临时 RPC 路径上返回。解密后的扁平 map 永远不碰持久存储——它只为那一次从控制面到 worker 的往返而存在。

由此有两点。其一，Agent Computer 是一个受信任的第一方运行时节点；它收到解密的 secret，因为它被信任，并且它没有机会去解析另一个 agent 的环境。其二，对一个 WorkerEnv 值的改动，在下一个回合生效，不在一个已经在跑的回合上生效——那个正在跑的回合已经有了它的环境。这和 [Background Agent Jobs](../background-agent-jobs/) 里描述的 worker secret 改动的“下一个回合，不是这一个回合”性质是同一件事。

## 它与 AppConfigure、Control Plane Plugins 的区别

Ankole 有三套触及进程或 shell 行为的配置界面，WorkerEnv 是其中专门持有 worker 回合 shell 变量的那套：

- **AppConfigure** 持有运维者管理的应用设置——包括那些已声明的 WorkerEnv 定义本身。当一个已声明变量带着 `worker_env_name` 标记时，AppConfigure 拥有它的 schema、加密、描述和按 agent 的覆盖；WorkerEnv 只投影解析后的值。`agent_computer_worker_envs` 里的一行自定义，是当没有已声明定义时，运维者的自由形态逃生口。
- **Control Plane Plugins** 在启动时贡献 AppConfigure 键和受监督子进程。一个 plugin 可以声明一个带 `worker_env_name` 的 AppConfigure 键；一旦声明，这个变量就像任何已声明变量一样流经 WorkerEnv。plugin 是声明的来源；WorkerEnv 是向 shell 的投影。
- **WorkerEnv** 是合并后的、按名路由的、RPC 时解密的 shell 环境。配置不住在这里；shell 变量从这里到达 worker。

这种划分让每套界面对自己拥有什么保持诚实：AppConfigure 拥有设置，plugin 拥有声明，WorkerEnv 拥有 shell 投影和 secret 处理纪律。

## WorkerEnv 不是什么

它不是通用 secret 存储。它持有 worker 回合的 shell 变量，在静态存储时按行密钥加密，仅此而已。它不是给模型运维者未批准的凭证的途径——绑定派生变量来自运维者所绑定的已激活 adapter，保留名是禁区。它的合并形态也不持久；那个解密的扁平 map 只存在一跳 RPC。持久的事实是那些行；合并后的环境每个回合重建一次。

## 下一步

- 收到这份环境的 worker，读 [Agent Computer](../agent-computer/)。
- 已声明变量所来自的 AppConfigure 定义，读 [Console](../console/)。
- 与 secret 改动共享的“下一个回合，不是这一个回合”性质，读 [Background Agent Jobs](../background-agent-jobs/)。
