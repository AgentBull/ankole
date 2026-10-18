# Ankole Helm Chart

[English](README.md)

本 Chart 部署开源版 Ankole 控制面。控制面通过 Kubernetes API 为每个需要 Worker
的 Agent 创建一个 Agent Computer Worker Pod。Chart 也可以部署 Ankole
PostgreSQL 18 镜像。该镜像已包含 `pg_search` 和 `vector`。

站点是一套完整部署，可以包含多个租户。各租户拥有独立的人员、Agent、Brain 和外部
平台连接；站点管理员管理共享的提供商与基础设施。管理员控制台默认位于
`/site-admin-console`；本次升级后 `/console` 返回 404。需要其他路径时，设置
Helm values 中的 `controlPlane.siteAdminConsolePath`，并将路径保存在运维配置中。普通用户通过自己的
OIDC 应用登录，不使用站点管理控制台。

## 前置条件

- Kubernetes 1.27 或更高版本。
- Helm 3 或更高版本。
- Linux `amd64` 或 `arm64` 节点池。
- 默认共享 Agent Home PVC 需要支持 `ReadWriteMany` 的 StorageClass；也可以用
  `worker.storage.claimTemplate` 为每个 Agent 配置独享 PVC。
- `worker.cache.type` 为 `pvc`（默认值）时，为 Worker 缓存盘提供支持
  `ReadWriteOnce` volume 的 StorageClass。
- 为首次设置和 Console 浏览器流程提供 HTTPS Ingress。
- 根据模型负载提供足够的 CPU、内存和存储。每个运行的 Agent 都有自己的
  Worker Pod，Pod 资源取自 values 中的 `worker.resources`。

Worker Pod 不需要额外的内核权限：容器就是每个 Agent 的隔离边界。Chart 为控制面
提供一个 namespace 级 Role，允许它创建和删除 Pod、Secret 和 PVC；并为 Worker Pod
提供单独的、没有任何权限的 ServiceAccount。

## 使用内置 PostgreSQL 安装

内置 PostgreSQL 容器使用 `C.utf8`，空卷首次初始化为 UTF8。已有卷的数据库编码
保持不变。先检查 `SHOW server_encoding`；SQL_ASCII 旧库需要另行执行
[备份、转换与恢复](../../../devkit/postgres-for-ankole/README.md)。

内置 PostgreSQL 只有一个副本，默认没有防止自愿驱逐的配置。生产环境应使用外部
PostgreSQL。若在 Karpenter 管理的节点上使用内置数据库，可添加 Pod 注解：

```yaml
postgresql:
  podAnnotations:
    karpenter.sh/do-not-disrupt: "true"
```

该注解阻止 Karpenter 合并节点，并可阻止 drift；它不提供数据库故障转移。
强制中断和 NodeClaim 上配置的 `terminationGracePeriod` 可以绕过该注解，见
[Karpenter 驱逐规则](https://karpenter.sh/docs/concepts/disruption/)。
Chart 不默认添加 PodDisruptionBudget：阻止唯一副本被驱逐的 PDB 会卡住节点升级。
需要移除注解以维护节点时，先安排数据库停机窗口。

先创建 namespace 和 bootstrap Secret。显式创建 Secret 可以避免首次安装失败后，
PostgreSQL PVC 保留旧密码，而下一次安装生成了新密码。

```sh
kubectl create namespace ankole

POSTGRES_PASSWORD="$(openssl rand -hex 24)"
ANKOLE_SECRET_BASE="$(openssl rand -hex 32)"
RELEASE_COOKIE="$(openssl rand -hex 32)"

kubectl -n ankole create secret generic ankole-bootstrap \
  --from-literal="POSTGRES_PASSWORD=${POSTGRES_PASSWORD}" \
  --from-literal="ANKOLE_SECRET_BASE=${ANKOLE_SECRET_BASE}" \
  --from-literal="RELEASE_COOKIE=${RELEASE_COOKIE}" \
  --from-literal="DATABASE_URL=ecto://ankole:${POSTGRES_PASSWORD}@ankole-postgresql:5432/ankole"

unset POSTGRES_PASSWORD ANKOLE_SECRET_BASE RELEASE_COOKIE
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

替换域名、Ingress 配置和 StorageClass 名称。`fullnameOverride` 会把 PostgreSQL
Service 名称固定为 `ankole-postgresql`，与 Secret 中的地址一致。

安装：

```sh
helm upgrade --install ankole ./tools/deploy/helm/ankole-agent \
  --namespace ankole \
  --values values-production.yaml \
  --wait \
  --timeout 15m
```

迁移 init container 会创建两个必需的 PostgreSQL extension，并执行所有待执行的
Ecto migration。迁移成功后，控制面才会启动。

## 使用外部 PostgreSQL 安装

外部数据库必须是 PostgreSQL 18 或更高版本。它必须 preload `pg_search`，并且
应用数据库 owner 必须能使用 `pg_search` 和 `vector`。

安装前，在 `DATABASE_URL` 实际指向的服务器上执行：

```sql
SHOW server_version_num;
SHOW shared_preload_libraries;

SELECT name, default_version, installed_version
FROM pg_available_extensions
WHERE name IN ('pg_search', 'vector')
ORDER BY name;
```

`server_version_num` 必须不小于 `180000`，`shared_preload_libraries` 必须包含
`pg_search`。

创建 Secret：

```sh
ANKOLE_SECRET_BASE="$(openssl rand -hex 32)"
RELEASE_COOKIE="$(openssl rand -hex 32)"

kubectl -n ankole create secret generic ankole-bootstrap \
  --from-literal="ANKOLE_SECRET_BASE=${ANKOLE_SECRET_BASE}" \
  --from-literal="RELEASE_COOKIE=${RELEASE_COOKIE}" \
  --from-literal="DATABASE_URL=ecto://ankole:REPLACE_ME@postgres.example.com:5432/ankole"

unset ANKOLE_SECRET_BASE RELEASE_COOKIE
```

在 `values-production.yaml` 中设置：

```yaml
secrets:
  existingSecret: ankole-bootstrap

postgresql:
  enabled: false
```

然后执行与内置数据库方案相同的 Helm 安装命令。

## 首次设置

等待所有 workload：

```sh
kubectl -n ankole get pods
kubectl -n ankole rollout status deployment/ankole-control-plane --timeout=10m
```

此时还没有 Worker Pod。创建 Agent 时，控制面为它创建 Worker。

从控制面日志读取 activation code：

```sh
kubectl -n ankole logs deployment/ankole-control-plane \
  -c control-plane | grep "SETUP ACTIVATION CODE"
```

打开 `https://ankole.example.com/setup`，输入 code，选择 Control Plane Plugin，
然后配置管理员的身份源。生产镜像使用 secure cookie，因此浏览器设置
流程必须使用 HTTPS。

设置完成后，通过 Console 配置模型提供商、模型档案、Agent Library 能力、
Agent、聊天渠道绑定和 WorkerEnv 密钥。不要把模型提供商的 API key
写进 Helm values。

## 镜像策略和升级

只支持从 v0.70.0 或更高版本直接升级到本版本。不支持从更早的版本升级。

默认固定控制面 `2.0.0-alpha.5` 和 `values.yaml` 中的 PostgreSQL digest。
这是预发布版本。请使用同一发布版本的部署文件和镜像；`main-latest` 可能指向
启动契约不同的旧版本。受控生产升级前，解析并记录控制面 digest：

```yaml
controlPlane:
  image:
    digest: sha256:CONTROL_PLANE_DIGEST
```

控制面镜像已带有与它匹配的不可变 Worker 镜像引用。`worker.image` 留空即可使用该引用。
若改用其他 PostgreSQL tag，也要清空 `postgresql.image.digest`；digest 的优先级高于 tag。
只有显式覆盖时才设置 `worker.image.repository` 及其 tag 或 digest；覆盖镜像必须与控制面来自同一源码 revision。

升级后，控制面会在 Agent 空闲时替换镜像与当前配置不同的 Worker；正在运行的 Job
继续使用旧 Worker，直到 Job 结束。RuntimeFabric 协议版本不同的 Worker
会立即被替换。替换实例保留 Agent Home 和 Codex Home。

从池化 Worker 版本升级时，先把旧控制面和 Worker Deployment 缩容到零，等待全部
Pod 消失。不要使用 `--grace-period=0` 或强制删除 Pod。按下面的步骤准备旧共享 PVC，
**成功后才启动新控制面**。种子导入与旧 Agent 的 provider 指派在同一个事务里完成。

每次升级前备份 PostgreSQL、Agent Home 和文件存储，然后执行：

```sh
helm upgrade ankole ./tools/deploy/helm/ankole-agent \
  --namespace ankole \
  --values values-production.yaml \
  --wait \
  --timeout 15m
```

新控制面 Pod 会先执行 migration。Helm rollback 不会反向执行数据库 migration。
如果应用回滚还需要 schema 回滚，请恢复数据库备份。

默认 provider 使用保留的共享 Agent Home PVC，通常是
`<release>-ankole-agent-agents`。每个 Worker 只把本 Agent 的目录挂到 `/workspace`，
`/agents/<agent_uid>` 是指向它的符号链接。更改 release 名称时，用
`worker.agents.persistence.existingClaim` 指定旧 PVC。

旧 Worker 以 root 运行，每个旧 Agent Home 的模式是 0700。新 Worker 的命令、
Codex、MCP、浏览器和 Automation 以 uid 1000 运行；持有凭证的 Worker 仍以 root 运行。
一次性云盘导入以 uid 10001 读取旧文件。停止全部旧写者后，按存储类型准备旧 PVC：

- **Pod 里的 root 在文件上就是 root**，例如块存储、本地卷，以及以
  `no_root_squash` 导出的 NFS：把下面的 `<claim>` 换成旧 PVC 名称，运行准备 Pod。
- **NFS 映射 root**（NFS 的默认设置）：服务器把 Pod 里的 root 映射为匿名用户。
  旧 Home 属于这个匿名用户，但它不能把文件改为属于 uid 1000，所以准备 Pod 中的
  `chown` 报 `Operation not permitted`。在 NFS 服务器上以 root 执行准备 Pod 的
  三条命令，把 `/agents` 换成这个 PVC 在服务器上的目录。新 Worker 需要 root 写入
  和 `chown`；运行时可使用 `no_root_squash`，或把所有访问映射到
  `all_squash,anonuid=1000,anongid=1000`。
- **经 POSIX 用户为 1000、组为 1000 的接入点访问 EFS**：所有访问都以 uid 1000
  进行，旧 Worker 的写入也是，所以文件已经属于 uid 1000，不需要准备。

```sh
kubectl -n ankole run ankole-agent-home-prepare --rm -i --restart=Never \
  --image=busybox:1.37 --overrides='{"apiVersion":"v1","spec":{
    "containers":[{"name":"prepare","image":"busybox:1.37",
      "securityContext":{"runAsUser":0},
      "command":["sh","-ec","chown -R 1000:1000 /agents; chmod 2777 /agents; chmod -R a+rX /agents"],
      "volumeMounts":[{"name":"agents","mountPath":"/agents"}]}],
    "volumes":[{"name":"agents","persistentVolumeClaim":{"claimName":"<claim>"}}]}}'
```

等待命令成功。它把旧 Home 改为属于 uid 1000；把根目录设为属组 1000、模式 2777，
让 uid 1000 能写入 kubelet 为新 Agent 建立的目录；还让导入能够读取旧文件。

然后用 `--set files.importAgentHomeClaim=<claim>` 升级，它会把这个 PVC 以只读方式
挂载到控制面的 `/agents`；再执行导入：

```sh
kubectl -n ankole exec deployment/ankole-control-plane -c control-plane -- \
  /app/bin/ankole eval 'Ankole.Release.import_agent_home("/agents")'
```

之后去掉这个值再升级一次。导入会复制每个 Agent 的已安装 Skill 和 Automation Job
脚本，不覆盖云盘已有文件，并报告跳过或无法读取的文件。用户文件、会话文件和 Job
工作区留在 Agent Home。

旧版本删除 Agent 时没有删除它的 Home。导入报告会列出这些目录（“No Agent has the
UID of …”）。新 Agent 使用自动生成的 UID。确认这些孤立目录的文件不再需要后，
可以删除目录。经过上面的准备，这些文件属于 uid 1000，所以用 `"runAsUser":1000`
运行准备 Pod，命令为 `["rm","-rf","/agents/<uid>"]`。

Chart 在所有控制面副本数下都使用 `Recreate`。升级会产生短暂服务中断，
但旧控制面不会在新版本修改数据库 schema 时继续运行。升级期间 Worker Pod
继续运行，并连接到新控制面。

## 存储和备份

一致备份之前，禁用 Agent 并等待工作结束，通过平台正常删除结束实例。等待控制面
记录实例消失和当前存储引用后，再停控制面，一起备份 PostgreSQL、文件存储与全部
Home。只停控制面不会结束 Worker。密钥管理系统要保留原 `ANKOLE_SECRET_BASE`，
它还用于解密未结清 generation 的凭据。

Agent Home 与 Codex Home 是持久数据。默认 provider 使用共享 PVC；
`worker.storage.claimTemplate` 为每个 Agent 建立独享 PVC。这些 PVC 没有 Worker
owner reference，Chart 管理的共享 PVC 还带有 `helm.sh/resource-policy: keep`。
删除 Pod、更换镜像或卸载 Chart 都保留 Agent Home；它需要与 PostgreSQL 和文件
存储一起备份。

安装标签（`worker.installation`，为空时是 release 名称）是 Worker Pod、Secret 与
PVC 的名称和标签的一部分。名称为 1–20 个字符，只接受小写字母、数字和连字符，首尾
必须是字母或数字。Chart 会转成小写、截到 20 个字符并移除末尾连字符；应选择无需这些
转换的名称。首次安装后不能修改。标签变了，控制面会为独享 Home 新建
空的 PVC，也看不到正在运行的 Worker，可能再启动一个写同一份 Home 的 Worker。用另一个
release 名称安装 Chart 时，把 `worker.installation` 设为原来的标签。

独立的缓存盘挂到 `/var/cache/ankole`，保存 Codex SQLite。缓存 PVC 在删除实例和
更换镜像后保留；重建 Worker 或更改实例配置时删除。`worker.cache.type=emptyDir`
则在删除 Pod 时丢失缓存。缓存丢失不会删除 Agent Home。

ConfigMap `<fullname>-agent-workers` 只拥有 Worker Pod、契约 Secret 和缓存 PVC，
`helm uninstall` 或设置 `worker.localPods=false` 的升级会删除这些对象。删除 Agent
时，先删除实例，再删除持久存储和缓存。

内置 PostgreSQL StatefulSet 在删除或缩容后保留 PVC。请单独备份数据库：

```sh
backup_path="ankole-$(date +%Y%m%d).dump"
kubectl -n ankole exec statefulset/ankole-postgresql -- \
  pg_dump -U ankole -d ankole -Fc > "$backup_path.partial" || exit 1
pg_restore -l "$backup_path.partial" > "$backup_path.list" || exit 1
mv "$backup_path.partial" "$backup_path"
```

检查每条命令的退出码。文件非空不能证明备份成功。导出或归档检查失败时，上面的命令
保留 `.partial` 文件；只有两条命令都成功才改为正式文件名。主机上的 `pg_restore`
版本必须能读取 PostgreSQL 18 归档。`-l` 只检查归档目录，不代替独立数据库上的完整
恢复演练。

若 `kubectl exec` 截断导出，保留诊断信息，设置
`KUBECTL_REMOTE_COMMAND_WEBSOCKETS=false`，再重新导出并检查归档。不要把截断的文件
用作备份。

数据库位于 `postgresql.pgdata` 指定的目录，默认是 PostgreSQL 卷上的 `pgdata`：
EBS 这类块存储卷的根目录有 `lost+found`，而 `initdb` 需要一个空目录。早期的 Chart
把数据库放在卷的根目录。升级这样的安装时，设置
`postgresql.pgdata=/var/lib/pgsql/18/data`，让 PostgreSQL 打开已有的数据库。

控制面把 Agent 云盘保存在 `files.store` 选择的文件存储中，支持 `fs`、`s3`、`azblob`、
`d1`、`cos`、`postgresql`、`oss`、`tos`、`gcs`、`sftp` 和 `webdav`。S3 以外的远程后端
使用 `controlPlane.extraEnv` 配置文档中的 `ANKOLE_FILES_*` 变量，凭据变量放在
`secrets.existingSecret`。控制面和迁移容器都会从这个 Secret 读取环境变量，
见[云盘存储指南](../../../../app/website/src/content/docs/drive-storage/zh-Hans-CN.md)。选择 `fs` 时，Chart 创建一个
`ReadWriteOnce` PVC，挂载到 `/var/lib/ankole/files`，`helm uninstall` 时保留它；
Pod 的 `fsGroup` 让它可写。选择 `s3` 时，云盘在桶中；请给桶配置一条中止未完成分段上传的
生命周期规则，因为控制面在大文件上传中途停止时，已上传的分段会留在桶里。PostgreSQL 记录了
每个云盘文件，因此数据库和文件存储要一起备份和恢复。

同时使用存储供应商的 snapshot 机制保护 PostgreSQL 和文件存储 volume，或使用桶的
备份机制。请在独立安装中验证恢复流程。

## 日常运维

```sh
# 查看 workload
kubectl -n ankole get deployments,statefulsets,pods,pvc,ingress

# 控制面日志
kubectl -n ankole logs deployment/ankole-control-plane -c control-plane -f

# Worker Pod，每个需要 Worker 的 Agent 一个
kubectl -n ankole get pods -l ankole.io/installation=ankole

# 单个 Worker 的日志；annotation ankole.io/agent-uid 标明它属于哪个 Agent
kubectl -n ankole logs POD_NAME -c worker -f

# 控制面 Pod 卡住时查看 migration 日志
kubectl -n ankole logs POD_NAME -c db-migrate

# 检查 PostgreSQL readiness 和 extension
kubectl -n ankole exec statefulset/ankole-postgresql -- \
  psql -U ankole -d ankole -c "SELECT extname, extversion FROM pg_extension WHERE extname IN ('pg_search', 'vector') ORDER BY extname"
```

## 主要配置

| 配置 | 默认值 | 用途 |
| --- | --- | --- |
| `secrets.existingSecret` | 空 | 已有 bootstrap Secret |
| `controlPlane.image.tag` | `2.0.0-alpha.5` | 不可变的已发布版本 |
| `controlPlane.image.digest` | 空 | 固定控制面镜像 |
| `controlPlane.publicHost` | `ankole.example.com` | Phoenix 对外域名 |
| `worker.image.digest` | 空 | 显式覆盖 Worker 镜像时使用的 digest |
| `worker.cache.type` | `pvc` | Worker 缓存盘：`pvc`（实例删除后保留）或 `emptyDir` |
| `worker.cache.size`、`worker.cache.storageClass` | `20Gi`、空 | 缓存盘的容量和 StorageClass |
| `worker.resources` | 空 | 每个 Worker Pod 的资源 |
| `worker.runtimeClassName` | 空 | Worker Pod 的 RuntimeClass，例如 `gvisor` |
| `worker.installation` | release 名称 | 本 release 的 Worker 对象名称中的标签；首次安装后不能修改 |
| `worker.localPods` | `true` | 创建 release 命名空间中 Worker Pod 需要的对象；`false` 删除它们 |
| `worker.providers` | 空 | 完整初始 provider 列表，替换默认种子 |
| `worker.providerConfig` | 空 | 默认 Kubernetes provider 的完整原始 YAML |
| `worker.storage` | 空 | 空值使用共享 PVC；`claimTemplate` 使用独享 PVC |
| `worker.agents.persistence` | RWX、`100Gi` | 保留的共享 Agent Home PVC |
| `worker.idleReleaseAfter` | `15m` | 默认种子的空闲回收策略 |
| `files.store` | `fs` | 云盘存储：`fs`（一个副本）、`s3`、`azblob`、`d1`、`cos`、`postgresql`、`oss`、`tos`、`gcs`、`sftp` 或 `webdav` |
| `files.persistence.size` | `100Gi` | `fs` 文件存储 PVC 的容量 |
| `files.s3.bucket`、`files.s3.region` | 空 | `s3` 的桶和区域 |
| `files.s3.endpoint` | 空 | Cloudflare R2 等 S3 兼容存储的端点 |
| `files.importAgentHomeClaim` | 空 | 为一次性导入，把这个 Agent Home PVC 只读挂载到控制面 |
| `postgresql.enabled` | `true` | 部署内置 PostgreSQL |
| `postgresql.persistence.enabled` | `true` | 持久化内置 PostgreSQL |
| `postgresql.pgdata` | `/var/lib/pgsql/18/data/pgdata` | 数据库目录；早期 Chart 创建的安装设为 `/var/lib/pgsql/18/data` |
| `ingress.enabled` | `false` | 创建 Ingress |

设置 `secrets.existingSecret` 后，Secret 必须包含：

- `ANKOLE_SECRET_BASE`
- `DATABASE_URL`
- `RELEASE_COOKIE`，控制面节点的 Erlang distribution cookie
- 使用内置 PostgreSQL 时还需要 `POSTGRES_PASSWORD`

使用静态凭据的 `s3` 文件存储时，它还可以包含 `ANKOLE_FILES_S3_ACCESS_KEY_ID` 和
`ANKOLE_FILES_S3_SECRET_ACCESS_KEY`。不提供时，控制面使用默认 AWS 凭据链，例如
EKS Pod Identity。provider 种子可以通过
`/etc/ankole/bootstrap/<key>` 读取这个 Secret 中的任意凭据键。控制面只读挂载它。

没有设置已有 Secret 时，Chart 可以在安装时生成缺少的 secret，并在正常升级时
保留它们。生产恢复场景使用显式 secret 管理更安全。

## Worker 文件中转

云盘传输在文件存储和 Worker 之间传送字节，途经处理这个 Worker 云盘请求的控制面
Pod。Chart 通过 Downward API 注入 `POD_IP`，控制面据此得出中转地址
`http://<POD_IP>:<PORT>`。Worker 必须能通过 HTTP 端口访问每个控制面 Pod IP；
只放行 Service 地址的 NetworkPolicy 会阻断文件传输。只有当 Worker 通过其他按
Pod 区分的地址访问控制面时，才在 `controlPlane.extraEnv` 中设置
`ANKOLE_RUNTIME_FABRIC_INTERNAL_ORIGIN`。

## 控制面副本

每个控制面 Pod 都是一个命名 Erlang 节点 `ankole@<POD_IP>`。Chart 渲染一个用于
节点发现的 headless Service，把 `DNS_CLUSTER_QUERY` 设为这个 Service，把生成的
`RELEASE_COOKIE` 存入 bootstrap Secret，并把 distribution 端口固定为
`controlPlane.distributionPort`。只有一个副本时，这些设置不起作用。
本版本在多个副本下也使用 `Recreate`：旧控制面 Pod 全部停止后，新 Pod 才执行数据库
迁移。Worker 在新控制面启动后重新连接。升级需要维护窗口，不支持新旧租户 schema
并行运行。只有最低支持的直接升级起点已包含租户归属，并且新旧受支持版本的 schema、
写入和持久任务兼容性已通过升级预演，才恢复 RollingUpdate。两个 release 数据步骤还要
保留到这些升级起点已包含身份配置作用域与每 Agent 的 Slack/Teams 配置键，且预演后
没有旧行；不能仅因当前站点已升级就删除。

`networkPolicy.enabled` 默认为 `false`。启用后，控制面策略允许控制面 Pod 访问
EPMD 和 distribution 端口。HTTP 对所有对端保持开放，因为 ingress controller
要提供 Console，Worker 也要访问每个 Pod IP 完成文件中转。`worker.localPods=true`
时，另一条策略选择 release 命名空间中带有本 installation 标签的 Worker Pod。
这条策略不添加入站放行规则。出站规则允许访问控制面的 HTTP 端口、**任意目标**的
TCP/UDP 53 端口，以及 `networkPolicy.workerDeniedCIDRs` 之外的 IPv4 地址。
DNS 规则也适用于这些 CIDR 内的地址，因此该配置不是绝对的私网地址拒绝列表。

策略生效需要网络插件支持 NetworkPolicy。其他适用策略可以增加放行范围，Pod
所在节点的通信也受 Kubernetes 的特殊规则影响，详见
[NetworkPolicy 契约](https://kubernetes.io/docs/concepts/services-networking/network-policies/)。
Chart 不配置其他 Worker Provider 或远程浏览器的网络。节点元数据保护仍由节点配置
负责；支持实例元数据 hop limit 的节点应将其设为 1。按英文指南的
[Worker 出站核验步骤](README.md#verify-worker-egress-in-a-deployment)检查实际部署：
从同一 Agent 的 `command`、本地浏览器和 Automation Job 请求受控的允许与拒绝
测试端点，并核对网络插件和端点日志。浏览器 SSRF 拒绝、远程浏览器结果、连接被拒绝
或超时本身都不能证明 Worker NetworkPolicy 已生效。

`files.store=fs` 只允许一个副本，副本数更多时 Chart 会拒绝渲染；需要多个副本时，
请使用共享远程存储后端。

在控制面单例进程（定时任务触发、聊天适配器连接、调度器状态加载）经验证可以安全
运行在多个节点上之前，请把 `controlPlane.replicaCount` 保持为 1。
迁移 init container 在每个新 Pod 中运行，使用现有数据库迁移锁。

## Worker Pod

控制面负责创建和删除 Worker Pod。Pod 没有 controller，`kubectl drain --force`
允许驱逐它们；保留正数终止宽限，等待 Pod 删除完成。Console 的工作节点页面显示
Worker 状态与平台返回的最新原因。

Worker 和存储清理 Pod 使用 root 启动可信进程，只保留 `SETUID`、`SETGID`、`CHOWN`、
`FOWNER`、`DAC_OVERRIDE` 和 `KILL`，保持 `allowPrivilegeEscalation: false`。
命名空间需要允许 Pod Security 的 baseline 级别；Worker 不满足 restricted 级别。
共享 NFS 必须允许 root 写入并设置新文件的 uid，或通过接入点把文件操作统一映射为
uid 1000。没有这种映射的 `root_squash` 导出不支持该运行方式。

provider 的 `idleReleaseAfter` 控制空闲回收。Kubernetes 删除实例，保留持久存储和
缓存。`agent_computer.worker.ready_timeout`（默认 10 分钟）限制 Worker 未就绪时长。

## Provider 种子

Secret `<fullname>-worker-providers` 保存 `providers.yaml`。控制面只在首次启动、
`worker_providers` 表为空时导入它。之后在 Console 增加和修改 provider；再改种子的
values 不会修改已存的 provider。默认种子使用 `worker.resources`、调度设置、
`extraEnv` 和探针。`worker.providerConfig` 提供完整 YAML，不与默认值合并；
`worker.providers` 提供完整 provider 列表，可包含不同类型或规格。每个 `config`
字符串原样保留，包括注释。

默认共享 PVC 的 provider 标记为 `legacy_agents: true`。独享布局不会自动指派旧
Agent；先把它的文件迁到目标存储，再在 Console 选择 provider。原始配置如果使用
其他 owner ConfigMap、ServiceAccount、PVC、命名空间或集群，请另行准备这些资源
及控制面权限。

Chart 创建哪些对象不看种子，只看 `worker.localPods`。它为 `true`（默认）时，Chart
创建 release 命名空间中 Worker Pod 需要的对象：owner ConfigMap、Worker
ServiceAccount、控制面的 Role 与 RoleBinding、Worker NetworkPolicy；`worker.storage`
与 `worker.agents.persistence.existingClaim` 都为空时，还有共享 Agent Home PVC。
只有在没有任何 provider 在这个命名空间运行 Worker 时才设为 `false`，并在
`worker.providers` 中列出初始 provider。设为 `false` 会删除这些对象；Kubernetes
随之删除 owner ConfigMap 拥有的全部 Worker Pod、契约 Secret 与缓存 PVC，这个命名空间
中已存的 Kubernetes provider 也失去 Role 与 ServiceAccount。共享 PVC 及其中的数据保留。

## Cloudflare 上的 Worker

先部署适配器及其 R2 存储，步骤见
[适配器 README](../../cloudflare/agent-workers/README.zh-Hans.md)。部署适配器时，
把控制面镜像提供的 Worker 镜像引用映射到 Cloudflare 镜像。显式设置 `worker.image` 会覆盖所有 Worker provider 使用的引用。

已经在运行的安装，在 Console 创建 Cloudflare provider。只运行 Cloudflare Worker
的新安装，把 provider 写入种子，并关闭本地 Worker Pod：

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

设置 `secrets.existingSecret`，指向包含 `worker-adapter-token` 与必需启动键的
Secret；token 不进 `config`。三个端点都必须能从 Cloudflare
访问，Worker Channel 需要支持 WebSocket。provider 设置 `relayOrigin` 时，只允许
一个控制面副本。

## 故障排查

- Worker Pod 一直处于 `Pending`，通常表示 StorageClass 无法绑定它的缓存 PVC，
  或者没有资源足够的节点。Console 的工作节点页面和 `kubectl describe pod`
  会显示原因。
- `db-migrate` init container 卡住，通常表示 `DATABASE_URL` 错误、PostgreSQL
  尚未就绪，或者缺少必需 extension。
- Worker 正在运行但一直没有 ready，通常表示 Worker 无法通过控制面 Service 的
  HTTP 端口建立 WebSocket 连接。超过 `agent_computer.worker.ready_timeout` 后，
  控制面会替换实例，Agent Home 仍在持久存储上。
- 控制面无法创建 Worker 时，会在日志中记录缺少的 Kubernetes 权限。请检查控制面
  ServiceAccount 的 Role 和 RoleBinding。
- 输入 activation code 后设置页面又回到原状态，通常表示 HTTPS 连接不受信任。
  请检查 Ingress certificate 和转发后的 host。
