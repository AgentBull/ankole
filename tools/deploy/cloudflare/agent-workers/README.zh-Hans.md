# 在 Cloudflare Containers 上运行 Agent Worker

[English](README.md)

本适配器供 Ankole 的 Cloudflare `WorkerProvider` 调用。每个 Agent 对应一个 `AgentWorker`
Durable Object 和一个 R2 前缀（`agents/<agent_uid>/`）：Durable Object 负责管理该 Agent 的容器实例并记录最近一次完成的目录备份（`DirectoryBackup`），适配器注册表则按运行方（Provider）筛选 Agent。

## 前提条件

- 已开通 Workers Paid 与 Containers 的 Cloudflare 账户。
- 在 `wrangler.json` 中将 R2 存储桶绑定为 `BACKUPS`。
- 与当前 Ankole 发布版本对应的 `linux/amd64` Worker 镜像；镜像内置的 `sandbox-shim` 版本须与适配器依赖的 `@cloudflare/sandbox` 版本一致（当前为 `1.0.0`）。
- 可从 Cloudflare 公网访问的 Worker Channel、文件中转与 AIGateway 端点（填写在下方的运行方 YAML 中，且每个端点均受凭据保护）。

请先在仓库根目录执行 `bun install`，再进入本目录运行以下命令。这些命令会直接发布云端资源，本地自动化测试不会调用它们。

## 部署步骤

1. 执行 `bunx wrangler login` 登录 Cloudflare，创建 R2 存储桶，并将桶名填入 `wrangler.json`。后续升级时请保留该存储桶与 Durable Object 绑定，因为其中保存着 Agent Home 备份数据与备份引用。

2. 确认控制面拉起 Worker 时使用的镜像引用（即 `ANKOLE_AGENT_COMPUTER_IMAGE`，下文记作 `<worker-image>`）。在 Helm Chart 中，该值由 `worker.image` 渲染：若设置了 `worker.image.digest`，格式为 `<repository>@<digest>`，否则为 `<repository>:<tag>`（例如 `ghcr.io/agentbull/ankole-agent-computer-worker@sha256:<worker-digest>`）；在 Docker Compose 中，则是控制面镜像内置的配套 Worker 镜像。拉取该镜像并推送至 Cloudflare 容器仓库，记下推送输出中的镜像摘要（digest）：

   ```bash
   docker pull --platform linux/amd64 <worker-image>
   docker tag <worker-image> ankole-worker:<revision>
   bunx wrangler containers push ankole-worker:<revision>
   ```

3. 部署适配器。每个命令行参数都将一个镜像引用名称映射到固定摘要的 Cloudflare 镜像；左侧名称必须与 `<worker-image>` 完全一致，且长度不超过 Wrangler 限制的 128 个字符。控制面对所有运行方统一使用同一个 `<worker-image>` 引用：在同时混合使用 Kubernetes 与 Cloudflare Worker 的环境中，Kubernetes 直接拉取 `<worker-image>`，而 Cloudflare 适配器则启动该名称所映射的镜像：

   ```bash
   bun run deploy <worker-image>=registry.cloudflare.com/<account-id>/ankole-worker@sha256:<digest>
   ```

   部署脚本会生成 `wrangler.deploy.json` 并调用 Wrangler。若未找到匹配的镜像名称，控制面不会创建 Cloudflare 容器，并在 Worker 最近错误中记录 `cloudflare_image_not_deployed`。

4. 执行 `bunx wrangler secret put ANKOLE_ADAPTER_TOKEN` 配置适配器访问令牌，并将同一个令牌填入 Ankole 运行方单独加密存储的 `adapterToken` 字段（切勿写入明文 YAML）。

5. 在控制台新建 Cloudflare 运行方并填入以下配置（也可通过 [Helm Chart](../../helm/ankole-agent/README.zh-Hans.md#cloudflare-上的-worker) 写入初始种子），随后在创建 Agent 时选用该运行方：

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

`instance` 既可填写 Cloudflare 预设规格名，也可传入 `{cpus, memoryMiB, diskMB}`；实例磁盘容量必须足以容纳容器镜像及恢复后的 Agent Home。修改 `instance` 规格会在 Worker 空闲时触发实例替换，而更新凭据或调整 `stopGraceSeconds` 不会替换实例。运行方创建后，`adapterUrl` 不可更改。此外，文件中转请求必须回到签发该中转 URL 的控制面节点；若使用共享的公网 `relayOrigin`，控制面必须保持单副本运行。

## 存储与替换

Cloudflare 容器实例的本地磁盘是临时存储：即使在同一实例代次（Generation）内发生容器重启（例如因内存不足重启），新容器也可能挂载一块全新空盘。每次容器入口脚本成功恢复 `/workspace` 后，都会在实例盘 `/workspace` 之外写入恢复标记。启动时若磁盘上没有该标记，入口脚本会先请求适配器恢复 `/workspace`，再启动 Worker：适配器优先恢复当前代次最近一次完成的备份；若当前代次尚无备份，则回退恢复 PostgreSQL 中已提交的备份引用，随后清理该 Agent R2 前缀下的旧备份对象。若恢复失败，或在 Worker 启动前收到停止信号，入口脚本会直接退出，既不启动 Worker，也不发起备份。

收到 `SIGTERM` 时，监督进程会先排空在途工作并终止剩余写入进程；收到 `SIGUSR1` 时则立即终止写入进程。随后，仅当磁盘上存在恢复标记时，入口脚本才会请求目录备份，防止尚未恢复的空目录覆盖 R2 中已有的有效备份。适配器会先持久化备份结果，入口脚本随后才退出；控制面必须先读取到这条备份记录，才会将该实例标记为已下线并拉起下一代实例。位于 `/var/cache/ankole` 的 SQLite 缓存属于可重建数据，不纳入备份。

适配器会在 Durable Object 存储中记录每一个已结束或已被拒绝的代次编号，并拒绝晚到的同代次创建请求，防止迟到请求重新恢复已被取代的旧备份。删除 Agent 时，适配器会一并清理其 R2 备份、凭据、运行状态及注册表项；但由于网络延迟请求没有最大到达时限，代次墓碑记录会永久保留在 Durable Object 存储中，其体积随已结束或被拒绝的代次数量线性增长。

请将 `stopGraceSeconds` 设得足够充裕，以容纳任务排空与目录上传。若容器触发内存溢出（OOM）、收到 `SIGKILL`、备份上传失败，或被平台强制终止（包括控制面中断超过适配器 6 小时保活上限的情形），上次成功备份之后的修改可能会丢失。

## 升级与卸载

升级 Worker 镜像时，先推送新镜像，并以控制面新的 Worker 镜像引用（如 Helm values 中更新后的 `worker.image`）新增一条适配器映射，同时保留在途 Worker 仍在使用的旧名称映射，随后再升级控制面。更换镜像时会直接从 R2 恢复 Agent Home，不依赖容器仓库快照。

升级 `@cloudflare/sandbox` 版本时，请先停用该运行方下的全部 Agent，等待所有容器完成备份并退出；随后部署新版适配器 SDK 及内置同版本 `sandbox-shim` 的新 Worker 镜像，更新目标镜像引用后再重新启用 Agent。若旧版 `sandbox-shim` 容器仍在运行时先行部署新版 SDK，可能导致备份与恢复失败。

卸载环境前，请先在 Ankole 中删除相关 Agent，等待容器实例与 R2 存储自动清理完毕，再使用 Wrangler 删除适配器、容器应用与镜像标签。手动清空 R2 对象前请先归档运维所需的备份；若其他运行方仍在共用同一个适配器，切勿将其删除。

## 本地检查

```bash
bun run test
bun run type-check
```

查看线上适配器的实时日志可执行 `bunx wrangler tail ankole-agent-workers`。
