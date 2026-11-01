# Ankole Helm Chart

[English](README.md)

本 Chart 用于部署开源版 Ankole 控制面。每当某个 Agent 需要运行环境时，控制面便通过
Kubernetes API 为其创建独立的 Agent Computer Worker Pod。此外，Chart 也可一并部署
内置 `pg_search` 与 `vector` 扩展的 Ankole PostgreSQL 18 镜像。

一个站点对应一套完整部署，内部可容纳多个租户：各租户拥有独立的人员、Agent、Brain
与外部平台集成，而共享提供商及底层基础设施则由站点管理员统一维护。站点管理控制台
默认挂载在 `/site-admin-console`；如需改用其他绝对路径，请在 Helm 配置中设置
`controlPlane.siteAdminConsolePath`，并将该路径同步记录到运维配置中。普通用户通过
所属租户域名或 OIDC 应用登录，不经由站点管理控制台进入系统。

## 前置条件

- Kubernetes 1.27 或更高版本。
- Helm 3 或更高版本。
- Linux `amd64` 或 `arm64` 节点池。
- 支持 `ReadWriteMany` 的 StorageClass（供默认的共享 Agent Home PVC 使用）；或者通过
  `worker.storage.claimTemplate` 为每个 Agent 分配独享 PVC。
- 当 `worker.cache.type` 为 `pvc`（默认值）时，需提供支持 `ReadWriteOnce` 存储卷的
  StorageClass 供 Worker 缓存盘使用。
- 用于首次初始化引导与 Console 浏览器访问的 HTTPS Ingress。
- 与模型工作负载相匹配的 CPU、内存和存储容量。每个运行中的 Agent 都会独占一个
  Worker Pod，其资源配额由 `worker.resources` 指定。

Worker Pod 无需额外的内核权限，容器本身即为每个 Agent 的隔离边界。Chart 会为控制面
创建命名空间级 Role 以管理 Pod、Secret 和 PVC 的生命周期，同时为 Worker Pod 分配
一个不带任何 Kubernetes 权限的独立 ServiceAccount。

## 使用内置 PostgreSQL 安装

内置 PostgreSQL 容器采用 `C.utf8` 区域设置，因此空存储卷在首次初始化时会创建为
UTF8 编码，而已有存储卷则保持原有数据库编码不变。接入已有存储卷前请先执行
`SHOW server_encoding` 检查编码；若旧库仍为 `SQL_ASCII`，请按
[备份、转换与恢复](../../../devkit/postgres-for-ankole/README.md)流程完成迁移。

内置 PostgreSQL Pod 将内存卷挂载到 `/dev/shm`，供并行查询使用。
`postgresql.sharedMemorySize` 默认为 `1Gi`；卷实际占用的内存计入容器内存限制，
运维人员需根据查询并发量调整两者。

内置 PostgreSQL 仅运行单副本，默认未配置防自愿驱逐保护，生产环境请改用外部
PostgreSQL 服务。如果必须在 Karpenter 托管节点上运行内置数据库，请为 Pod 添加以下注解：

```yaml
postgresql:
  podAnnotations:
    karpenter.sh/do-not-disrupt: "true"
```

添加该注解后，Karpenter 不会对该节点执行合并回收，也能延缓配置漂移替换，但这并不能
提供数据库故障转移能力。遇到强制中断或达到 NodeClaim 配置的
`terminationGracePeriod` 时，Pod 仍会被驱逐，详见
[Karpenter 驱逐规则](https://karpenter.sh/docs/concepts/disruption/)。Chart 默认不创建
PodDisruptionBudget——一旦限制单副本驱逐，节点升级便会卡死。因节点维护需要移除该注解前，
请提前安排数据库停机窗口。

安装前请先创建命名空间与引导 Secret。显式管理引导 Secret 可以避免首次安装失败后，
保留下来的 PostgreSQL PVC 仍沿用旧密码、而重试安装却生成新密码导致连接失败。

```sh
kubectl create namespace ankole

POSTGRES_PASSWORD="$(openssl rand -hex 24)"
ANKOLE_SECRET_BASE="$(openssl rand -hex 32)"
RELEASE_COOKIE="$(openssl rand -hex 32)"
ANKOLE_FUNCTION_RUNTIME_TOKEN="$(openssl rand -hex 32)"

kubectl -n ankole create secret generic ankole-bootstrap \
  --from-literal="POSTGRES_PASSWORD=${POSTGRES_PASSWORD}" \
  --from-literal="ANKOLE_SECRET_BASE=${ANKOLE_SECRET_BASE}" \
  --from-literal="RELEASE_COOKIE=${RELEASE_COOKIE}" \
  --from-literal="ANKOLE_FUNCTION_RUNTIME_TOKEN=${ANKOLE_FUNCTION_RUNTIME_TOKEN}" \
  --from-literal="DATABASE_URL=ecto://ankole:${POSTGRES_PASSWORD}@ankole-postgresql:5432/ankole"

unset POSTGRES_PASSWORD ANKOLE_SECRET_BASE RELEASE_COOKIE ANKOLE_FUNCTION_RUNTIME_TOKEN
```

创建 `values-production.yaml`：

```yaml
fullnameOverride: ankole

secrets:
  existingSecret: ankole-bootstrap

controlPlane:
  publicHost: ankole.example.com

worker:
  agents:
    persistence:
      storageClass: nfs
  cache:
    type: pvc
    storageClass: standard
    size: 20Gi

postgresql:
  enabled: true
  persistence:
    storageClass: standard
    size: 50Gi

ingress:
  enabled: true
  className: nginx
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt
  hosts:
    - host: ankole.example.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: ankole-tls
      hosts:
        - ankole.example.com
```

请按实际集群环境替换域名、Ingress 配置和 StorageClass 名称。将 `fullnameOverride`
设为 `ankole` 可使 PostgreSQL Service 名称固定为 `ankole-postgresql`，从而与引导
Secret 中的 `DATABASE_URL` 保持一致。

执行安装：

```sh
helm upgrade --install ankole ./tools/deploy/helm/ankole-agent \
  --namespace ankole \
  --values values-production.yaml \
  --wait \
  --timeout 15m
```

启动期间，迁移初始化容器会先创建两个必需的 PostgreSQL 扩展并执行全部待处理的 Ecto
数据库迁移；待迁移全部成功后，控制面才会启动。

## 使用外部 PostgreSQL 安装

外部数据库必须运行 PostgreSQL 18 或更高版本，在启动时预加载 `pg_search`，并允许应用
数据库所有者安装和使用 `pg_search` 与 `vector`。数据库中已安装的扩展版本及实际加载的
动态库版本均须满足
[Brain 版本契约](../../../../docs/design-docs/BrainV3.md#retrieval-index-recovery)。
升级已有部署（包括内置 PostgreSQL）时，请先停止控制面，按
[数据库镜像升级说明](../../../devkit/postgres-for-ankole/README.md)更新扩展后再部署新版 Pod。

默认 PostgreSQL 镜像为 `amd64` 和 `arm64` 架构提供 `pg_search` `0.26.4`。
使用自定义镜像时，请设置其发布摘要；如果通过标签选择镜像，请清空 `postgresql.image.digest`。

安装前，请先连接 `DATABASE_URL` 实际指向的数据库实例并核验版本与扩展：

```sql
SHOW server_version_num;
SHOW shared_preload_libraries;

SELECT name, default_version, installed_version
FROM pg_available_extensions
WHERE name IN ('pg_search', 'vector')
ORDER BY name;
```

其中 `server_version_num` 必须不小于 `180000`，且 `shared_preload_libraries` 必须包含
`pg_search`。

创建引导 Secret：

```sh
ANKOLE_SECRET_BASE="$(openssl rand -hex 32)"
RELEASE_COOKIE="$(openssl rand -hex 32)"
ANKOLE_FUNCTION_RUNTIME_TOKEN="$(openssl rand -hex 32)"

kubectl -n ankole create secret generic ankole-bootstrap \
  --from-literal="ANKOLE_SECRET_BASE=${ANKOLE_SECRET_BASE}" \
  --from-literal="RELEASE_COOKIE=${RELEASE_COOKIE}" \
  --from-literal="ANKOLE_FUNCTION_RUNTIME_TOKEN=${ANKOLE_FUNCTION_RUNTIME_TOKEN}" \
  --from-literal="DATABASE_URL=ecto://ankole:REPLACE_ME@postgres.example.com:5432/ankole"

unset ANKOLE_SECRET_BASE RELEASE_COOKIE ANKOLE_FUNCTION_RUNTIME_TOKEN
```

在 `values-production.yaml` 中关闭内置数据库并引用该 Secret：

```yaml
secrets:
  existingSecret: ankole-bootstrap

postgresql:
  enabled: false
```

随后执行与内置数据库方案相同的 `helm upgrade --install` 命令即可。

此外，`functionRuntime.image` 用于指定与控制面同版本的函数运行时镜像，其 Headless
Service 仅向控制面暴露已就绪的副本。函数运行时 Pod 不挂载数据库凭据或 ServiceAccount
令牌。所在集群必须启用 NetworkPolicy 强制执行：网络策略仅放行来自控制面的入站流量与
公网出站流量，因此必须在 `functionRuntime.deniedCIDRs` 中填入站点内网网段以及控制面、
数据库的公网地址。Chart 会自动生成并保留内部函数令牌；若配置了
`secrets.existingSecret`，则必须在 Secret 中提供 `ANKOLE_FUNCTION_RUNTIME_TOKEN`。

## 首次设置

等待所有工作负载就绪：

```sh
kubectl -n ankole get pods
kubectl -n ankole rollout status deployment/ankole-control-plane --timeout=10m
```

刚完成安装时尚不会创建 Worker Pod；待后续创建 Agent 时，控制面才会按需拉起对应的
Worker Pod。

从控制面日志中查看激活码：

```sh
kubectl -n ankole logs deployment/ankole-control-plane \
  -c control-plane | grep "SETUP ACTIVATION CODE"
```

在浏览器中打开 `https://ankole.example.com/setup`，输入激活码，选择所需的
Control Plane Plugin，并配置管理员身份提供商。由于生产镜像启用了安全 Cookie，浏览器
初始化流程必须通过 HTTPS 访问。

完成初始化后，即可在 Console 中配置模型提供商、模型档案、Agent Library 能力、Agent、
聊天渠道绑定及 WorkerEnv 密钥。切勿将模型提供商的 API 密钥直接写入 Helm 配置。

## 镜像策略和升级

仅支持从 v0.70.0 或更高版本直接升级，不支持从更早版本跨版本直接升级。

`values.yaml` 默认将控制面版本固定为预发布版 `2.0.0-alpha.24`，并通过镜像摘要固定
PostgreSQL 镜像。部署清单与容器镜像必须来自同一发布版本，切勿混用 `main-latest`（该标签
可能指向启动契约不同的旧版本）。执行受控生产升级前，请先解析并记录目标控制面镜像摘要：

```yaml
controlPlane:
  image:
    digest: sha256:CONTROL_PLANE_DIGEST
```

控制面镜像内置了与之匹配的不可变 Worker 镜像引用，将 `worker.image` 留空即可自动采用。
如需改用其他 PostgreSQL 镜像标签，请同时清空 `postgresql.image.digest`（镜像摘要的
优先级高于标签）。仅在确需覆盖默认 Worker 镜像时，才设置 `worker.image.repository` 及其
标签或摘要，且覆盖镜像必须与控制面构建自同一源码提交版本。

完成升级后，对于镜像与当前配置不一致的 Worker，控制面会在其所属 Agent 空闲时平滑替换；
正在执行的 Job 会继续在原 Worker 上运行直至结束。若 Worker 的 RuntimeFabric 协议版本
与新控制面不一致，则会立即替换。替换 Worker 实例期间，Agent Home 和 Codex Home 数据均会
完整保留。

若从旧的池化 Worker 版本升级，请先将旧控制面与 Worker Deployment 缩容至 `0`，并等待所有
Pod 彻底退出，切勿使用 `--grace-period=0` 或强制删除 Pod。**在启动新控制面之前**，必须先按
下文步骤准备好原有的共享 PVC，因为新控制面首次启动时会在同一数据库事务中导入 Worker
提供商种子并将存量 Agent 绑定到该 PVC。

如果旧版为每个 Agent 分配独享 PVC，且名称不含租户身份，请停掉控制面和 Worker，先完成
[独享 PVC 迁移](../../../../docs/upgrades/unified-drive.md#dedicated-kubernetes-claims)。

每次升级前请先备份 PostgreSQL、Agent Home 存储与文件存储，然后执行：

```sh
helm upgrade ankole ./tools/deploy/helm/ankole-agent \
  --namespace ankole \
  --values values-production.yaml \
  --wait \
  --timeout 15m
```

新控制面 Pod 启动前会先运行数据库迁移。执行 `helm rollback` 不会回滚已生效的数据库迁移；
如果回退应用版本的同时还需要回退数据库结构，请直接恢复数据库备份。

默认的 Worker 提供商使用保留的共享 Agent Home PVC（通常名为
`<release>-ankole-agent-agents`）。每个 Worker 将包含租户身份的存储目录挂载到
`/workspace`，并通过 `/agents/<agent_uid>` 符号链接指向该路径。升级仅用 Agent UID 命名目录的
共享卷时，请先完成[共享卷目录迁移](../../../../docs/upgrades/unified-drive.md#kubernetes-shared-agent-homes)。若变更了 Helm 发布名称，
请通过 `worker.agents.persistence.existingClaim` 显式指向原有 PVC。

旧版池化 Worker 以 root 身份运行，旧 Agent Home 目录权限为 `0700`；新版 Worker 中的命令、
Codex、MCP、浏览器和 Automation 脚本均以 uid `1000` 运行（仅持有凭据的 Worker 监管进程
以 root 运行），而一次性云盘导入任务则以 uid `10001` 读取旧文件。待所有旧写入进程全部停止后，
请按底层存储类型处理旧 PVC 权限：

- **Pod 内的 root 直接对应文件系统 root**（如块存储、本地卷，或以 `no_root_squash` 导出的
  NFS）：将下方命令中的 `<claim>` 替换为旧 PVC 名称，运行准备 Pod 即可。
- **开启了 `root_squash` 的 NFS**（NFS 默认行为）：NFS 服务器会将 Pod 内的 root 映射为匿名
  用户；旧 Home 虽归该匿名用户所有，但匿名用户无权通过 `chown` 将属主改为 uid `1000`，因此
  在准备 Pod 中执行 `chown` 会报 `Operation not permitted`。此时请直接登录 NFS 服务器，以
  root 身份对该 PVC 对应的导出目录（替换命令中的 `/agents`）执行准备 Pod 中的三条命令。此外，
  新版 Worker 运行时仍需 root 写入与 `chown` 权限，请将导出项改为 `no_root_squash`，或统一映射为
  `all_squash,anonuid=1000,anongid=1000`。
- **通过指定了 POSIX 用户 `1000`、组 `1000` 的接入点挂载 EFS**：包括旧版 Worker 写入在内的
  所有文件操作原本均以 uid `1000` 执行，文件已归属 uid `1000`，无需额外准备。

```sh
kubectl -n ankole run ankole-agent-home-prepare --rm -i --restart=Never \
  --image=busybox:1.37 --overrides='{"apiVersion":"v1","spec":{
    "containers":[{"name":"prepare","image":"busybox:1.37",
      "securityContext":{"runAsUser":0},
      "command":["sh","-ec","chown -R 1000:1000 /agents; chmod 2777 /agents; chmod -R a+rX /agents"],
      "volumeMounts":[{"name":"agents","mountPath":"/agents"}]}],
    "volumes":[{"name":"agents","persistentVolumeClaim":{"claimName":"<claim>"}}]}}'
```

等待准备 Pod 执行成功：该命令会将旧 Home 目录属主改为 uid `1000`，将根目录设为属组 `1000`
与权限 `2777`（以便 uid `1000` 写入 kubelet 为新 Agent 创建的子目录），并为后续导入开放旧文件
读取权限。

接着附带 `--set files.importAgentHomeClaim=<claim>` 执行升级，将该 PVC 以只读方式挂载到
控制面的 `/agents` 目录，随后运行导入命令：

```sh
kubectl -n ankole exec deployment/ankole-control-plane -c control-plane -- \
  /app/bin/ankole eval 'Ankole.Upgrade202610.import_agent_home("/agents")'
```

导入完成后，去掉 `files.importAgentHomeClaim` 参数再执行一次升级以卸载只读挂载。导入过程会将
各 Agent 已安装的 Skill、Automation Job 脚本及待发送的旧版附件内容复制到云盘（不会覆盖云盘中
同名已有文件，并会汇总输出跳过或无法读取的文件）；用户文件、会话文件与 Job 工作区仍保留在
Agent Home 中。移除旧存储卷前，请先根据导入报告处理所有缺失附件，以免挂起的旧版消息因等待附件
转换而受阻。

旧版本在删除 Agent 时不会自动清理对应的 Home 目录，导入报告会逐一列出这类孤立目录
（`"No Agent has the UID of …"`）。确认目录内文件无需保留后即可清理：由于准备步骤已将文件属主
改为 uid `1000`，可复用上方的准备 Pod 配置，将运行身份改为 `"runAsUser":1000`，并执行
`["rm","-rf","/agents/<uid>"]`。

无论配置多少个控制面副本，Chart 均固定采用 `Recreate` 更新策略。升级期间会产生短暂服务中断，
从而确保新版本执行数据库迁移时不会有旧版控制面同时读写数据库；与此同时，运行中的 Worker Pod
不会中断，待新控制面就绪后会自动重连。

## 存储和备份

执行一致性备份前，请先禁用所有 Agent 并等待在途任务结束，再通过平台正常销毁各 Worker 实例。
待控制面确认实例已退出并落盘最新存储引用后，停止控制面，将 PostgreSQL、文件存储与全部
Agent Home 一并备份（仅停止控制面并不会终止运行中的 Worker）。密钥管理系统中还须保留原始
`ANKOLE_SECRET_BASE`，以便解密提供商密钥及尚未结清世代（generation）的凭据。

Agent Home 与 Codex Home 均为持久化数据：默认 Worker 提供商挂载共享 PVC，而设置
`worker.storage.claimTemplate` 则会为每个 Agent 分配独享 PVC。这两类 PVC 均不挂接
Worker 属主引用（ownerReference），且 Chart 管理的共享 PVC 带有
`helm.sh/resource-policy: keep` 注解，因此删除 Pod、更换镜像或卸载 Chart 都不会清除
Agent Home。备份时请务必将 Agent Home 与 PostgreSQL、文件存储同步备份。

安装标签（取自 `worker.installation`，留空时默认取 Helm 发布名称）会拼入 Worker Pod、
Secret 与 PVC 的资源名及标签中。取值须为 1–20 个字符，仅允许小写字母、数字与连字符，且首尾
必须为字母或数字（Chart 会自动转为小写、截断至 20 个字符并去除末尾连字符，建议直接选用无需
转换的名称）。首次安装后切勿修改安装标签：一旦变更，控制面会为独享 Home 新建空白 PVC，同时
无法识别已在运行的旧 Worker，进而可能拉起第二个 Worker 并发写入同一份 Home。若需使用新的
Helm 发布名称重新部署，请将 `worker.installation` 显式设为原有标签。

独立缓存盘挂载在 `/var/cache/ankole`，用于存放 Codex SQLite 文件。当
`worker.cache.type` 为 `pvc` 时，销毁实例或更换镜像均会保留缓存 PVC，仅在重建 Worker 或
修改实例规格配置时才会清除；若设为 `emptyDir`，删除 Pod 即会清空缓存。无论缓存是否清空，
Agent Home 数据均不受影响。

属主 ConfigMap `<fullname>-agent-workers` 仅通过属主引用管理 Worker Pod、契约 Secret 与
缓存 PVC；执行 `helm uninstall` 或将 `worker.localPods` 设为 `false` 升级时，这些对象会随之
清理。删除 Agent 时，系统会先销毁运行实例，再清理对应的持久存储与缓存。

内置 PostgreSQL StatefulSet 在删除或缩容后仍会保留其 PVC，请独立执行数据库备份：

```sh
backup_path="ankole-$(date +%Y%m%d).dump"
kubectl -n ankole exec statefulset/ankole-postgresql -- \
  pg_dump -U ankole -d ankole -Fc > "$backup_path.partial" || exit 1
pg_restore -l "$backup_path.partial" > "$backup_path.list" || exit 1
mv "$backup_path.partial" "$backup_path"
```

请务必检查每一步的退出码，切勿仅凭输出文件非空就认定备份成功。上述脚本在导出或归档校验失败时
会保留 `.partial` 后缀，仅当两步全部成功时才重命名为正式备份文件。宿主机上的 `pg_restore`
客户端须支持 PostgreSQL 18 归档格式；此外，`-l` 参数仅校验归档目录索引，不能替代在独立数据库上
执行的完整恢复演练。

如果 `kubectl exec` 在传输过程中截断了导出流，请保留现场诊断信息，设置环境变量
`KUBECTL_REMOTE_COMMAND_WEBSOCKETS=false` 后重新导出并校验归档，切勿将截断的文件当作有效备份。

数据库集群存放在 `postgresql.pgdata` 指定的目录中，默认为 PostgreSQL 存储卷下的 `pgdata`
子目录（EBS 等块存储卷根目录自带 `lost+found`，而 `initdb` 要求目标目录为空）。早期版本的
Chart 曾直接将数据库初始化在存储卷根目录；升级这类存量环境时，请设置
`postgresql.pgdata=/var/lib/pgsql/18/data`，以便 PostgreSQL 直接加载原有数据目录。

控制面将 Agent 云盘存放在 `files.store` 指定的文件存储后端中，可选值包括 `fs`、`s3`、
`azblob`、`d1`、`cos`、`postgresql`、`oss`、`tos`、`gcs`、`sftp` 和 `webdav`。若选用 S3
以外的远程后端，请在 `controlPlane.extraEnv` 中配置对应的 `ANKOLE_FILES_*` 变量，并将凭据写入
`secrets.existingSecret`（控制面与迁移容器均会加载该 Secret 中的环境变量），详见
[云盘存储指南](../../../../app/website/src/content/docs/drive-storage/zh-Hans-CN.md)。选用
`fs` 时，Chart 会创建一块 `ReadWriteOnce` PVC 挂载到 `/var/lib/ankole/files`，借助 Pod 的
`fsGroup` 赋予写权限，并在执行 `helm uninstall` 时保留该存储卷。选用 `s3` 时，请为存储桶配置
自动中止未完成分段上传的生命周期规则，以免控制面在大文件上传中途退出后残留孤立分段。由于
PostgreSQL 记录了所有云盘文件的元数据，备份与恢复时必须保持数据库和文件存储一致。

除逻辑导出外，建议同时启用云厂商的存储卷快照（或对象存储桶备份）机制，并在独立环境中定期演练
完整恢复流程。

## 日常运维

```sh
# 查看工作负载状态
kubectl -n ankole get deployments,statefulsets,pods,pvc,ingress

# 查看控制面日志
kubectl -n ankole logs deployment/ankole-control-plane -c control-plane -f

# 查看按需创建的 Worker Pod
kubectl -n ankole get pods -l ankole.io/installation=ankole

# 查看单个 Worker 日志；注解 ankole.io/agent-uid 标明所属 Agent
kubectl -n ankole logs POD_NAME -c worker -f

# 控制面 Pod 启动受阻时查看数据库迁移日志
kubectl -n ankole logs POD_NAME -c db-migrate

# 检查 PostgreSQL 就绪状态与已安装扩展
kubectl -n ankole exec statefulset/ankole-postgresql -- \
  psql -U ankole -d ankole -c "SELECT extname, extversion FROM pg_extension WHERE extname IN ('pg_search', 'vector') ORDER BY extname"
```

## 主要配置

| 配置 | 默认值 | 用途 |
| --- | --- | --- |
| `secrets.existingSecret` | 空 | 指定已有的引导 Secret |
| `controlPlane.image.tag` | `2.0.0-alpha.24` | 不可变的已发布版本标签 |
| `controlPlane.image.digest` | 空 | 固定控制面镜像摘要 |
| `controlPlane.publicHost` | `ankole.example.com` | Phoenix 对外访问域名 |
| `worker.image.digest` | 空 | 显式覆盖 Worker 镜像时使用的镜像摘要 |
| `worker.cache.type` | `pvc` | Worker 缓存盘类型：`pvc`（销毁实例后保留）或 `emptyDir` |
| `worker.cache.size`、`worker.cache.storageClass` | `20Gi`、空 | 缓存盘容量与 StorageClass |
| `worker.resources` | 空 | 单个 Worker Pod 的资源配额 |
| `worker.runtimeClassName` | 空 | Worker Pod 使用的 RuntimeClass（如 `gvisor`） |
| `worker.installation` | Helm 发布名称 | 拼入当前发布下各 Worker 资源名称的安装标签；首次安装后不可更改 |
| `worker.localPods` | `true` | 创建当前命名空间运行本地 Worker Pod 所需的资源；设为 `false` 则清理这些资源 |
| `worker.providers` | 空 | 完整的初始 Worker 提供商列表（替换默认生成的种子） |
| `worker.providerConfig` | 空 | 默认 Kubernetes 提供商的完整原始 YAML 配置 |
| `worker.storage` | 空 | 留空时使用共享 PVC；配置 `claimTemplate` 时为每个 Agent 分配独享 PVC |
| `worker.agents.persistence` | RWX、`100Gi` | 持久化保留的共享 Agent Home PVC 配置 |
| `worker.idleReleaseAfter` | `15m` | 默认提供商种子的空闲实例回收时长 |
| `files.store` | `fs` | 云盘存储后端：`fs`（仅限单副本）、`s3`、`azblob`、`d1`、`cos`、`postgresql`、`oss`、`tos`、`gcs`、`sftp` 或 `webdav` |
| `files.persistence.size` | `100Gi` | `fs` 文件存储 PVC 的容量 |
| `files.s3.bucket`、`files.s3.region` | 空 | `s3` 存储桶名称与区域 |
| `files.s3.endpoint` | 空 | Cloudflare R2 等 S3 兼容存储的服务端点 |
| `files.importAgentHomeClaim` | 空 | 一次性迁移导入时，将指定的旧 Agent Home PVC 只读挂载到控制面 |
| `postgresql.enabled` | `true` | 是否部署内置 PostgreSQL |
| `postgresql.persistence.enabled` | `true` | 是否为内置 PostgreSQL 启用持久化卷 |
| `postgresql.pgdata` | `/var/lib/pgsql/18/data/pgdata` | 数据库数据目录；从早期 Chart 创建的存量环境升级时设为 `/var/lib/pgsql/18/data` |
| `ingress.enabled` | `false` | 是否创建 Ingress |

指定 `secrets.existingSecret` 后，目标 Secret 必须包含以下键：

- `ANKOLE_SECRET_BASE`
- `ANKOLE_FUNCTION_RUNTIME_TOKEN`
- `DATABASE_URL`
- `RELEASE_COOKIE`（控制面节点间的 Erlang 分布式通信 Cookie）
- `POSTGRES_PASSWORD`（启用内置 PostgreSQL 时必填）

若使用静态凭据连接 `s3` 文件存储，还可在同一 Secret 中提供 `ANKOLE_FILES_S3_ACCESS_KEY_ID`
与 `ANKOLE_FILES_S3_SECRET_ACCESS_KEY`；省略这两个键时，控制面默认走 AWS 标准凭据链（例如
EKS Pod Identity）。控制面会将该 Secret 以只读方式挂载到 `/etc/ankole/bootstrap/<key>`，
因此提供商种子也可直接从中读取任意自定义凭据。

未指定 `secrets.existingSecret` 时，Chart 会在首次安装时自动生成缺失密钥，并在常规升级中予以
保留；但在生产环境中，显式维护外部 Secret 更利于灾备恢复。

## Worker 文件中转

Worker 读写云盘文件时，数据流经由当前承接该请求的那个控制面 Pod 在文件存储与 Worker 之间中转。
Chart 通过 Downward API 向控制面注入 `POD_IP`，控制面据此拼出中转地址 `http://<POD_IP>:<PORT>`。
因此，Worker 必须能够直连每一个控制面 Pod IP 的 HTTP 端口；如果 NetworkPolicy 仅放行了
Service 虚拟 IP，文件中转将会失败。仅当 Worker 需要通过其他按 Pod 区分的地址访问控制面时，才需在
`controlPlane.extraEnv` 中配置 `ANKOLE_RUNTIME_FABRIC_INTERNAL_ORIGIN`。

## 控制面副本

每个控制面 Pod 都是一个具名 Erlang 节点（`ankole@<POD_IP>`）。Chart 会渲染一个用于节点发现的
Headless Service，将 `DNS_CLUSTER_QUERY` 指向该 Service，把生成的 `RELEASE_COOKIE` 存入引导
Secret，并将分布式通信端口固定为 `controlPlane.distributionPort`（单副本运行时这些集群参数不会
触发跨节点连接）。即便配置了多副本，Chart 依然采用 `Recreate` 策略：必须等所有旧控制面 Pod 完全
退出后，新 Pod 才会执行数据库迁移，随后各 Worker 再重连至新控制面。升级时请预留维护窗口，系统不支持
新旧租户数据库结构并行运行。

当 `networkPolicy.enabled` 设为 `true`（默认为 `false`）时，控制面网络策略允许控制面 Pod 之间
互访 EPMD 及分布式通信端口；HTTP 端口则对所有来源保持开放，以便 Ingress 控制器转发 Console 流量、
并允许 Worker 直连各 Pod IP 完成文件中转。当 `worker.localPods=true` 时，Chart 还会下发第二条
网络策略，选中当前命名空间内带有本安装标签的 Worker Pod：该策略不放行任何入站连接，出站仅放行控制面
HTTP 端口、发往**任意目标**的 TCP/UDP 53 端口（DNS），以及 `networkPolicy.workerDeniedCIDRs`
网段之外的 IPv4 地址。由于 53 端口放行规则同样覆盖 `workerDeniedCIDRs` 内部地址，该列表并非绝对的
私网完全封禁列表。

NetworkPolicy 需依赖支持网络策略的 CNI 插件才能实际生效；选中同一批 Pod 的其他策略可能会叠加放行
权限，而 Pod 与宿主机节点之间的流量还受 Kubernetes 自身路由规则支配，详见
[NetworkPolicy 契约](https://kubernetes.io/docs/concepts/services-networking/network-policies/)。
本 Chart 不接管外部 Worker 提供商或远程浏览器网络的隔离策略。请在节点侧自行加固云主机元数据防护
（支持实例元数据跳数限制的节点请将跳数限制设为 `1`），并参照英文指南中的
[Worker 出站核验步骤](README.md#verify-worker-egress-in-a-deployment)实测部署边界：通过测试专用
Agent 的 `command` 工具、本地浏览器及 Automation Job 分别访问受控的公网放行端点与私网拦截端点，
并交叉比对网络插件拒绝记录与目标端点访问日志——单纯出现浏览器 SSRF 拦截、远程浏览器代理请求、连接被拒
或超时，均不足以证明集群级 NetworkPolicy 已经生效。

当 `files.store=fs` 时仅支持单副本运行，若将副本数调高，Chart 会拒绝渲染模板；如需运行多副本，请改用
共享远程文件存储后端。

由于定时任务触发、聊天适配器长连接和调度器状态加载等控制面单例进程集中运行在单节点上，请将
`controlPlane.replicaCount` 保持为 `1`。每个新启动的控制面 Pod 都会在初始化容器中通过数据库迁移锁
串行执行迁移检查。

## Worker Pod

控制面直接通过 Kubernetes API 创建和销毁 Worker Pod。由于这类 Pod 不受 Deployment 等控制器托管，
排空节点时需加上 `kubectl drain --force` 方可驱逐；驱逐时请保留正数的终止宽限期，并等待 Pod 优雅
退出。可在 Console 的工作节点页面查看各 Worker 的实时状态及底层平台返回的最新状态原因。

Worker Pod 与存储准备 Pod 以 root 身份拉起受信任监管进程，保持 `allowPrivilegeEscalation: false`，
且仅保留 `SETUID`、`SETGID`、`CHOWN`、`FOWNER`、`DAC_OVERRIDE` 与 `KILL` 六项内核能力。因此，
所在命名空间须允许 Pod Security Standard 的 `baseline` 级别（不兼容 `restricted` 级别）。使用共享
NFS 时，导出配置必须允许 root 写入及更改文件属主，或者通过接入点将所有文件访问统一映射为 uid `1000`；
默认开启 `root_squash` 且未做 uid `1000` 映射的 NFS 导出无法满足 Worker 文件系统契约。

Worker 提供商配置中的 `idleReleaseAfter` 控制空闲实例回收时长：超时回收时，Kubernetes 仅销毁 Pod
实例，持久存储与缓存盘均会保留。`agent_workers.ready_timeout_seconds`（默认 10 分钟）则限制了
Worker 启动后未就绪的最长等待时间。

## Provider 种子

Secret `<fullname>-worker-providers` 内含渲染生成的 `providers.yaml`，控制面仅在首次启动且
`worker_providers` 表为空时导入一次。此后请在 Console 中新增或修改提供商配置，后续修改 Helm 种子
参数不会更新数据库中已落盘的提供商记录。默认生成的提供商种子会自动带入 `worker.resources`、节点调度
约束、`extraEnv` 及探针配置；如需提供不与默认值合并的完整原始 YAML，请设置 `worker.providerConfig`；
如需一次性定义多个不同类型或规格的提供商，请设置 `worker.providers`（其中每段 `config` 字符串包括注释
均会原样保留）。

默认生成的共享 PVC 提供商带有 `legacy_agents: true` 标记；而独享 PVC 存储布局不会自动接管存量旧
Agent，需先将其文件迁入目标存储，再前往 Console 手动指定提供商。若自定义配置引用了其他属主 ConfigMap、
ServiceAccount、PVC、命名空间或外部集群，请预先单独创建这些资源并授予控制面相应权限。

Chart 是否在当前命名空间创建本地 Kubernetes Worker 配套资源，完全取决于 `worker.localPods` 而非
提供商种子。当 `worker.localPods` 为默认的 `true` 时，Chart 会创建属主 ConfigMap、Worker
ServiceAccount、控制面 Role 与 RoleBinding、Worker NetworkPolicy，并在 `worker.storage` 与
`worker.agents.persistence.existingClaim` 均为空时一并创建共享 Agent Home PVC。仅当当前命名空间内
不运行任何本地 Worker 时，才可将该项设为 `false`，同时在 `worker.providers` 中显式列出初始提供商。
一旦将 `worker.localPods` 设为 `false`，Chart 会移除上述配套资源，触发 Kubernetes 级联清理属主
ConfigMap 名下的全部 Worker Pod、契约 Secret 与缓存 PVC，且数据库中指向本命名空间的存量 Kubernetes
提供商也会失去所需的 Role 和 ServiceAccount（共享 Agent Home PVC 及其文件数据仍会保留）。

## Cloudflare 上的 Worker

请先参照[适配器 README](../../cloudflare/agent-workers/README.zh-Hans.md) 部署 Cloudflare 适配器及配套
R2 存储桶。部署适配器时，需将控制面镜像内声明的 Worker 镜像引用映射为实际推送到 Cloudflare 的镜像（若在
Helm 中显式设置了 `worker.image`，则会同步改变所有 Worker 提供商收到的镜像引用）。

对于已在运行的环境，直接在 Console 中添加 Cloudflare 提供商即可；对于仅使用 Cloudflare Worker 的全新
安装环境，可将提供商写入种子配置并关闭本地 Worker Pod：

```yaml
worker:
  localPods: false
  providers:
    - provider_id: cloudflare
      kind: cloudflare
      display_name: Cloudflare
      is_default: true
      config: |
        adapterUrl: https://ankole-agent-workers.example.workers.dev
        instance: standard-3
        idleReleaseAfter: 15m
        endpoints:
          runtimeFabricUrl: wss://ankole.example.com/runtime-fabric/worker
          relayOrigin: https://ankole.example.com
          aiGatewayUrl: https://ankole.example.com/api/v1/ai-gateway
      credentials:
        adapterToken:
          file: /etc/ankole/bootstrap/worker-adapter-token
```

将 `secrets.existingSecret` 指向同时包含 `worker-adapter-token` 及各项必需启动密钥的 Secret，切勿将
令牌明文写进 `config`。上述三个服务端点均须允许从 Cloudflare 公网访问，其中 Worker Channel 端点必须支持
WebSocket 升级；此外，凡配置了 `relayOrigin` 的提供商均要求控制面保持单副本运行。

## 故障排查

- **Worker Pod 长时间停留在 `Pending`**：通常是 StorageClass 无法绑定缓存 PVC，或集群内缺少满足资源
  配额的节点。可通过 Console 工作节点页面及 `kubectl describe pod` 查看具体调度原因。
- **`db-migrate` 初始化容器卡住**：通常是 `DATABASE_URL` 连接串有误、PostgreSQL 尚未就绪，或数据库缺少
  必需扩展（`pg_search`、`vector`）。
- **Worker 已运行却迟迟未能就绪**：通常是 Worker 无法经由控制面 Service 的 HTTP 端口建立 WebSocket
  连接。超出 `agent_workers.ready_timeout_seconds` 时限后，控制面会自动替换该实例，而持久存储上的
  Agent Home 数据保持不变。
- **控制面无法创建 Worker**：控制面日志会打印缺失的 Kubernetes RBAC 权限，请核查控制面
  ServiceAccount 绑定的 Role 与 RoleBinding。
- **提交激活码后初始化页面反复刷新回原状态**：通常是浏览器到控制面的 HTTPS 链路不受信任或反向代理头缺失，
  请检查 Ingress TLS 证书与转发的 `Host` 请求头。
