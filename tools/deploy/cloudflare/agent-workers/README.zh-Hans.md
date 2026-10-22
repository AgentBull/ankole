# 在 Cloudflare Containers 上运行 Agent Worker

[English](README.md)

Cloudflare WorkerProvider 调用这个适配器。每个 Agent 有一个 `AgentWorker`
Durable Object 和一个 R2 前缀 `agents/<agent_uid>/`。Durable Object 持有容器，
记录最后完成的 `DirectoryBackup`；Registry 按 provider 过滤 Agent。

## 前提

- Cloudflare 账户开通 Workers Paid 和 Containers。
- 在 `wrangler.json` 中把 R2 桶绑定为 `BACKUPS`。
- 发布版本的 `linux/amd64` Worker 镜像，内含与适配器的 `@cloudflare/sandbox`
  版本一致的 `sandbox-shim`（当前为 1.0.0）。
- Cloudflare 能访问的 Worker Channel、文件中转和 AIGateway 公网端点，写在下面
  的 provider YAML 中；各端点都要求凭据。

先在仓库根目录执行 `bun install`，再在本目录执行以下命令。这些命令会发布云资源，
本地测试不执行它们。

## 部署

1. 用 `bunx wrangler login` 登录。创建 R2 桶，把名称写入 `wrangler.json`。
   升级时保留桶和 Durable Object 绑定，它们保存 Agent 数据和备份引用。

2. 找出控制面创建 Worker 所用的镜像引用，即它的 `ANKOLE_AGENT_COMPUTER_IMAGE`，
   下文记为 `<worker-image>`。Helm Chart 从 `worker.image` 渲染它：设置了
   `worker.image.digest` 时是 `<repository>@<digest>`，否则是
   `<repository>:<tag>`，例如
   `ghcr.io/agentbull/ankole-agent-computer-worker@sha256:<worker-digest>`。
   Compose 用控制面镜像内置的 Worker 镜像。推送这个镜像，记下推送输出的 digest：

   ```bash
   docker pull --platform linux/amd64 <worker-image>
   docker tag <worker-image> ankole-worker:<revision>
   bunx wrangler containers push ankole-worker:<revision>
   ```

3. 部署适配器。每个参数把一个名称映射到固定 digest 的镜像，名称必须与
   `<worker-image>` 完全相同，Wrangler 只接受不超过 128 个字符的名称。控制面为它的
   全部 provider 使用这一个引用：同时有 Kubernetes 与 Cloudflare Worker 的安装中，
   Kubernetes 拉取它，适配器启动映射到它的镜像。

   ```bash
   bun run deploy <worker-image>=registry.cloudflare.com/<account-id>/ankole-worker@sha256:<digest>
   ```

   脚本生成 `wrangler.deploy.json` 并交给 Wrangler。没有名称匹配时，控制面不创建
   Cloudflare Worker，Worker 的最近错误为 `cloudflare_image_not_deployed`。

4. 用 `bunx wrangler secret put ANKOLE_ADAPTER_TOKEN` 设置适配器 token；同一个值
   填入 provider 单独的 `adapterToken` 密钥字段，不进 provider YAML。

5. 在 Console 创建 Cloudflare provider，配置如下；创建 Agent 时选择它。
   [Helm Chart](../../helm/ankole-agent/README.zh-Hans.md#cloudflare-上的-worker)
   也可以把它放入初始种子。

   ```yaml
   adapterUrl: https://ankole-agent-workers.example.workers.dev
   instance: standard-3
   env: {}
   endpoints:
     runtimeFabricUrl: wss://ankole.example.com/runtime-fabric/worker
     relayOrigin: https://ankole.example.com
     aiGatewayUrl: https://ankole.example.com/api/v1/ai-gateway
   stopGraceSeconds: 300
   idleReleaseAfter: 15m
   ```

`instance` 可以是平台规格名，也可以是 `{cpus, memoryMiB, diskMB}`。实例盘必须容纳
镜像和恢复后的 Agent Home。修改实例设置会在空闲时替换 Worker，修改凭据和终止
宽限不会。provider 创建后不能改适配器地址。文件中转必须到达签发 URL 的控制面节点；
共享公网中转地址要求单个控制面副本。

## 存储与替换

实例盘是临时的。同一代内的容器重启（例如内存不足后）可能换成新盘。入口恢复成功后，
在实例盘上 `/workspace` 之外写一个恢复标记；盘上没有标记时，入口先请适配器恢复
`/workspace`，再启动 Worker。适配器恢复本代最近一次备份；本代还没有备份时，恢复
PostgreSQL 已提交的备份引用。恢复成功后，删除这个 Agent 前缀下的其他备份对象。
恢复失败，或 Worker 启动前收到停止信号时，入口不启动 Worker，也不请求备份。

SIGTERM 让监督进程排水并结束剩余写者；SIGUSR1 让它立即结束写者，然后请求目录
备份。只有带恢复标记的盘才请求备份，避免未恢复的 Home 取代已保存的备份。适配器
先保存备份结果，入口再退出。控制面必须读取这个记录，才能把实例置为 absent 并创建
下一代。`/var/cache/ankole` 中的 SQLite 缓存不备份。

适配器记录每个已结束或确定被拒绝的 generation，拒绝这一代迟到的创建请求，避免
再次恢复旧备份。删除 Agent 时清除备份、凭据、运行状态和 Registry 项；generation
标记留在 Durable Object 存储中。请求没有最大迟到期限，因此标记不过期，其占用
随已结束或被拒绝的 generation 数增长。

`stopGraceSeconds` 要容纳排水与备份。OOM、SIGKILL、备份失败或平台强制停止可能
丢失最后完成的备份之后的修改；控制面停机超过适配器的六小时保活上限也可能触发
这类停止。

## 升级

推送新镜像，用控制面新的 Worker 镜像引用（例如 Helm values 中新的 `worker.image`）
作为名称映射它，同时保留仍有 Worker 使用的名称，然后升级控制面。更换镜像从 R2 恢复
Agent Home，不依赖 registry 快照。

升级 `@cloudflare/sandbox` 时，先停用这个 provider 的全部 Agent，等待实例完成
备份并消失，再部署新 SDK 和匹配的 `sandbox-shim` 镜像，修改目标镜像后重新启用。
旧 shim 仍运行时部署新 SDK，可能导致备份和恢复失败。

卸载前先在 Ankole 删除 Agent，等实例和存储清理完成，再用 Wrangler 删除适配器、
容器应用和镜像标签。删除 R2 对象前保留运维所需的备份；其他 provider 仍使用同一
适配器时不能删除它。

## 本地检查

```bash
bun run test
bun run type-check
```

部署后的日志用 `bunx wrangler tail ankole-agent-workers` 查看。
