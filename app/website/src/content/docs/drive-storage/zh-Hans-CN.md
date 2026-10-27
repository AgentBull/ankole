---
title: 控制面云盘与对象存储配置
description: 为 Ankole.ObjectStore（Agent 云盘、Pod file 页面、各类附件与已编译 Applet 产物包）配置本地文件、云存储桶、数据库表、SFTP 或 WebDAV，并说明迁移与备份要求。
section: Guides
order: 318
---

控制面对象存储（`Ankole.ObjectStore`）通过 `ANKOLE_FILES_STORE` 配置，统一承载每个 Agent 的云盘（Worker 停止期间仍可读写）、Pod `file` 页面、Pod 文档/Base/Chat 与对话附件，以及已编译的 Applet 产物包。其中，路径、权限和内容引用保存在 PostgreSQL 中，按内容寻址的对象字节则存放在 OpenDAL 后端。Ankole 支持 `fs`、`s3`、`azblob`、`d1`、`cos`、`postgresql`、`oss`、`tos`、`gcs`、`sftp` 和 `webdav`。

对象存储属于站点级启动配置，同一站点下的所有租户共用同一后端。WorkerProvider 的持久 Home、缓存盘以及 Cloudflare R2 备份需单独配置，详见 [WorkerProvider 与缓存盘](../worker-providers/)；面向用户的云盘操作说明见 [文件管理](../file-management/)。

## 选择后端

| 部署 | `ANKOLE_FILES_STORE` | 使用方式 |
| --- | --- | --- |
| 单机或一个控制面副本 | `fs` | 持久卷或本地文件夹 |
| AWS S3 | `s3` | 存储桶、区域（Region）和 AWS 凭据链 |
| Cloudflare R2 | `s3` | S3 API 端点、区域设为 `auto`、R2 凭据 |
| 其他 S3 兼容服务 | `s3` | 服务端点地址、签名区域和凭据，上线前需验证实际兼容性 |

若要运行多个控制面副本，各副本必须连接同一套远程共享存储，并使用完全一致的后端地址与根路径；当 `files.store: fs` 且副本数大于 1 时，官方 Helm Chart 会直接拒绝渲染模板。同时，将对象存储切换为 S3 并不会解除部分 WorkerProvider 对控制面单副本的限制。

由于定时触发、聊天渠道长连接和调度器状态加载等控制面单例进程均在单节点上运行，生产部署请将 `controlPlane.replicaCount` 保持为 `1`。远程共享存储只是多副本的必要条件之一，仅靠切换存储并不能直接开启多副本，详见 [控制面副本说明](https://github.com/AgentBull/ankole/blob/main/tools/deploy/helm/ankole-agent/README.md#control-plane-replicas)。

## 环境变量

| 变量 | 适用后端 | 要求 |
| --- | --- | --- |
| `ANKOLE_FILES_STORE` | 全部 | 生产环境必填，用于选择受支持的存储后端 |
| `ANKOLE_FILES_FS_ROOT` | `fs` | 控制面容器或进程内可写的绝对路径 |
| `ANKOLE_FILES_S3_BUCKET` | `s3` | 预先创建好的存储桶名称 |
| `ANKOLE_FILES_S3_REGION` | `s3` | 必填；AWS 填写存储桶所在区域，R2 填写 `auto` |
| `ANKOLE_FILES_S3_ENDPOINT` | `s3` | S3 兼容服务的端点地址；AWS S3 通常留空 |
| `ANKOLE_FILES_S3_ROOT` | `s3` | 可选的对象键前缀，如 `/ankole/production/` |
| `ANKOLE_FILES_S3_ACCESS_KEY_ID` | `s3` | 可选静态凭据，须与下一项同时设置 |
| `ANKOLE_FILES_S3_SECRET_ACCESS_KEY` | `s3` | 可选静态凭据，须与上一项同时设置 |

未配置静态凭据时，控制面默认走 AWS 凭据链（包括已配置的 EKS Pod Identity）。存储凭据和工作负载身份只需提供给控制面；Worker 通过 RuntimeFabric 读写自己的云盘，无需持有存储桶密钥。上述变量均在进程启动时读取，修改后需重启控制面才能生效。请勿将本页未列出的其他 OpenDAL 参数直接拼作 Ankole 环境变量。

## 其他 OpenDAL 后端

其他后端的环境变量统一采用 `ANKOLE_FILES_<SCHEME>_<FIELD>` 格式，后端标识与字段名均使用大写字母。例如，连接 Azure Blob 需设置 `ANKOLE_FILES_STORE=azblob`、`ANKOLE_FILES_AZBLOB_CONTAINER` 和 `ANKOLE_FILES_AZBLOB_ENDPOINT`。下表列出了 Ankole 支持的全部字段；若必填字段缺失或为空，控制面启动会直接失败。

| 后端 | 必填字段 | 可选字段 |
| --- | --- | --- |
| `azblob` | `CONTAINER`, `ENDPOINT` | `ROOT`, `ACCOUNT_NAME`, `ACCOUNT_KEY`, `SAS_TOKEN` |
| `d1` | `ACCOUNT_ID`, `DATABASE_ID`, `TOKEN`, `TABLE`, `KEY_FIELD`, `VALUE_FIELD` | `ROOT` |
| `cos` | `BUCKET`, `ENDPOINT` | `ROOT`, `SECRET_ID`, `SECRET_KEY`, `SECURITY_TOKEN` |
| `postgresql` | `CONNECTION_STRING`, `TABLE`, `KEY_FIELD`, `VALUE_FIELD` | `ROOT` |
| `oss` | `BUCKET`, `ENDPOINT` | `ROOT`, `ACCESS_KEY_ID`, `ACCESS_KEY_SECRET`, `SECURITY_TOKEN` |
| `tos` | `BUCKET`, `ENDPOINT`, `REGION` | `ROOT`, `ACCESS_KEY_ID`, `SECRET_ACCESS_KEY`, `SECURITY_TOKEN` |
| `gcs` | `BUCKET` | `ROOT`, `ENDPOINT`, `CREDENTIAL`, `CREDENTIAL_PATH` |
| `sftp` | `ENDPOINT` | `ROOT`, `USER`, `KEY`, `KNOWN_HOSTS_STRATEGY` |
| `webdav` | `ENDPOINT` | `ROOT`, `USERNAME`, `PASSWORD`, `TOKEN` |

各类凭据均应保存在控制面的部署 Secret 中。GCS 的 `CREDENTIAL` 为经 Base64 编码的凭据 JSON，`CREDENTIAL_PATH` 则指向原始 JSON 文件路径；若两者均未提供，控制面将使用上游 Google 默认凭据链。SFTP 调用控制面镜像内置的 `ssh` 客户端，`KEY` 填写私钥文件路径；主机指纹校验策略默认为 `strict`，需预先配置控制面运行用户的 `~/.ssh/known_hosts`。WebDAV 支持用户名密码（Basic）认证或 Bearer `TOKEN` 认证。

使用 D1 或 PostgreSQL 作为对象存储后端时，必须预先手动建表——Ankole 不会自动创建这张表。其中 D1 表需使用 `TEXT` 主键与 `BLOB` 值列，PostgreSQL 表需使用 `TEXT` 主键与 `BYTEA` 值列，再通过 `TABLE`、`KEY_FIELD` 和 `VALUE_FIELD` 指定表名与列名。需要注意，D1、PostgreSQL 和 WebDAV 后端在读写时都会在内存中缓冲完整对象；此外，D1 的[字符串、BLOB 和单行大小上限均为 2,000,000 字节](https://developers.cloudflare.com/d1/platform/limits/)，且 Ankole 不会跨行拆分单个对象。若有大文件存储需求，请改用对象存储桶后端。

SFTP 后端在写入时会先在目标路径旁生成临时文件，写完关闭后再重命名落盘，因此服务端必须支持原子替换重命名（例如 OpenSSH 的 `posix-rename` 扩展）。若控制面进程在写入中途异常退出，存储目录中可能会残留 `blobs/<digest>.<uuid>.tmp` 临时文件，可在所有写入进程停止的维护窗口内统一清理。

在 Helm 部署中，通过 `files.store` 选择后端：非敏感变量填入 `controlPlane.extraEnv`，凭据变量放入 `secrets.existingSecret`。Chart 会将该 Secret 注入控制面容器和数据库迁移容器的环境变量，同时在控制面容器内将其只读挂载至 `/etc/ankole/bootstrap`；若使用 SFTP，私钥文件权限与 `known_hosts` 都必须允许 uid 10001 读取。在 Docker Compose 部署中，可参考下文覆盖文件（override）的写法，将所选后端的变量同时传给迁移服务与控制面服务。正式上线前，请逐一验证对象的读取、写入、覆盖替换、删除及大文件传输。

## 本地文件夹与持久卷

```dotenv
ANKOLE_FILES_STORE=fs
ANKOLE_FILES_FS_ROOT=/var/lib/ankole/files
```

`ANKOLE_FILES_FS_ROOT` 填写控制面进程视角下的路径。容器化部署必须将该路径挂载到持久化存储上，否则重建或删除容器就会丢失全部文件。控制面镜像以 uid/gid 10001 运行，该用户必须对该目录具备创建、写入、重命名和删除权限；`fs` 后端还会在根目录下自动创建 `.tmp` 子目录。

官方 Docker Compose 默认已将 `files_data` 命名卷挂载到 `/var/lib/ankole/files`。若需改用宿主机目录，请先创建目录并授予 uid/gid 10001 写权限，再通过 Compose 覆盖文件替换卷挂载：

```yaml
services:
  control-plane:
    volumes:
      - ./ankole-files:/var/lib/ankole/files
```

对已有数据的站点更换挂载目录前，必须先把原存储卷中的内容完整复制过去，切勿直接将空目录挂载到同一路径——替换挂载并不会自动迁移旧卷中的文件。

Helm 的本地存储配置如下：

```yaml
controlPlane:
  replicaCount: 1
files:
  store: fs
  persistence:
    size: 100Gi
    storageClass: YOUR_STORAGE_CLASS
    # existingClaim: YOUR_EXISTING_FILES_PVC
```

Chart 会创建（或接管已有）文件 PVC 并挂载至 `/var/lib/ankole/files`，且在卸载 Release 时默认保留由 Chart 创建的 PVC。复用已有 PVC 时，同样需确保目录权限符合要求并纳入备份范围。该 PVC 仅承载控制面对象存储（如云盘与附件），Agent 持久 Home 使用独立的存储配置。

## AWS S3

先创建私有 S3 存储桶，并为控制面配置 IAM 身份权限，允许在所选前缀下读取、写入、删除对象以及执行分段上传（Multipart Upload）；若存储桶启用了 KMS 加密，还需授予配套的 KMS 加解密权限。

```dotenv
ANKOLE_FILES_STORE=s3
ANKOLE_FILES_S3_BUCKET=ankole-files
ANKOLE_FILES_S3_REGION=ap-southeast-1
ANKOLE_FILES_S3_ROOT=/ankole/production/
```

若使用 AWS 工作负载身份（如 EKS Pod Identity 或 IAM Role），可省略静态凭据变量；若使用静态访问密钥，则需在部署 Secret 中同时提供 `ANKOLE_FILES_S3_ACCESS_KEY_ID` 与 `ANKOLE_FILES_S3_SECRET_ACCESS_KEY`。

Helm 配置示例：

```yaml
files:
  store: s3
  s3:
    bucket: ankole-files
    region: ap-southeast-1
    root: /ankole/production/
```

可通过 `secrets.existingSecret` 引用包含上述两项 S3 密钥的引导 Secret；该 Secret 还必须一并包含部署所需的数据库凭据（`DATABASE_URL`，以及启用内置 PostgreSQL 时的 `POSTGRES_PASSWORD`）、原 `ANKOLE_SECRET_BASE`、`ANKOLE_FUNCTION_RUNTIME_TOKEN` 与 `RELEASE_COOKIE`。Chart 也支持通过 `secrets.filesS3AccessKeyID` 和 `secrets.filesS3SecretAccessKey` 传入密钥，但切勿将真实密钥明文提交到 values 文件中。

## Cloudflare R2 与其他 S3 兼容服务

Cloudflare R2 同样复用 `s3` 后端：

```dotenv
ANKOLE_FILES_STORE=s3
ANKOLE_FILES_S3_BUCKET=ankole-files
ANKOLE_FILES_S3_REGION=auto
ANKOLE_FILES_S3_ENDPOINT=https://ACCOUNT_ID.r2.cloudflarestorage.com
ANKOLE_FILES_S3_ROOT=/ankole/production/
ANKOLE_FILES_S3_ACCESS_KEY_ID=YOUR_R2_ACCESS_KEY_ID
ANKOLE_FILES_S3_SECRET_ACCESS_KEY=YOUR_R2_SECRET_ACCESS_KEY
```

请使用 R2 专用的 S3 API 访问密钥；`ANKOLE_FILES_S3_ENDPOINT` 需填写账户级 S3 API 端点地址，而非公开访问域名或 Cloudflare Worker URL。关于 `auto` 区域设置及受支持的接口范围，请参阅 [R2 S3 API 兼容说明](https://developers.cloudflare.com/r2/api/s3/api/)。使用 Helm 部署时，对应设置 `files.s3.endpoint`、`files.s3.region` 和 `files.s3.root` 即可。

MinIO 等其他 S3 兼容存储同样将后端设为 `s3`，并填写实际端点地址与签名区域。存储服务宣称兼容 S3 并不代表所有行为完全一致，正式上线前务必实测读取、写入、删除、分段上传及大文件传输。Ankole 仅开放本页列出的后端与启动字段，不支持 S3 虚拟主机风格寻址或自定义签名参数。底层参数细节可参考 OpenDAL 的 [S3 后端文档](https://opendal.apache.org/docs/rust/opendal/services/struct.S3.html)。

## Compose 使用 S3

官方 `compose.yaml` 在配置中将对象存储后端固定为 `fs`，仅在 `.env` 中添加 `ANKOLE_FILES_STORE=s3` 并不会覆盖该设置。请新建一份覆盖文件（例如 `compose.files-s3.yaml`），把相同的存储配置同时传给数据库迁移服务与控制面服务。以下示例采用静态凭据：

```yaml
x-files-environment: &files-environment
  ANKOLE_FILES_STORE: s3
  ANKOLE_FILES_S3_BUCKET: ${ANKOLE_FILES_S3_BUCKET:?Set the files bucket}
  ANKOLE_FILES_S3_REGION: ${ANKOLE_FILES_S3_REGION:?Set the files region}
  ANKOLE_FILES_S3_ENDPOINT: ${ANKOLE_FILES_S3_ENDPOINT:-}
  ANKOLE_FILES_S3_ROOT: ${ANKOLE_FILES_S3_ROOT:-/ankole/}
  ANKOLE_FILES_S3_ACCESS_KEY_ID: ${ANKOLE_FILES_S3_ACCESS_KEY_ID:?Set the access key}
  ANKOLE_FILES_S3_SECRET_ACCESS_KEY: ${ANKOLE_FILES_S3_SECRET_ACCESS_KEY:?Set the secret key}
services:
  migrate:
    environment: *files-environment
  control-plane:
    environment: *files-environment
```

在 `.env` 或部署环境中填好对应变量值后，新建站点可直接按下列命令启动；已有数据的站点请先完成下一节的文件迁移：

```sh
docker compose -f compose.yaml -f compose.files-s3.yaml up -d
```

后续执行 `run`、`exec`、版本升级和一次性 Home 导入命令时，也必须同时带上这两个 `-f` 参数，确保所有操作都写入同一个存储后端。若改用 AWS 默认凭据链，请移除覆盖文件中对两项静态凭据的必填校验，并向容器注入实际的工作负载身份。

## 更换后端、桶或前缀

切换存储配置本身不会自动搬运已有文件。PostgreSQL 中只记录内容引用，底层对象则以 `blobs/<完整 SHA-256>` 为键存放在所选根目录或 S3 前缀下，并非按 Agent 云盘里的文件夹名称组织目录。

1. 暂停外部请求与定时任务，停用所有 Agent 并等待在途工作结束；随后停止全部 Worker 与控制面实例，防止迁移期间继续产生文件提交或触发清理任务。
2. 将数据库、原对象存储、Agent 持久 Home 及部署密钥一并完整备份。
3. 将原存储下的 `blobs/` 目录完整复制到新后端的目标根目录或前缀下，保持对象键不变（从本地文件系统复制时排除 `.tmp` 目录），切勿按云盘逻辑路径重命名对象。
4. 更新所有控制面实例的存储配置，确认均指向同一目标后启动服务，依次验证历史文件的下载与内容完整性、新文件上传、Worker 云盘读写以及对话附件收发。
5. 验证通过后恢复业务运行，并暂留原存储用于应急回滚。若回滚时还需保留切换后新写入的数据，也必须将对应的底层对象与数据库引用一并同步回原存储。

切勿让两个独立的 Ankole 站点共用同一个对象存储前缀——任一站点的未引用对象清理任务，都可能把另一站点仍在使用的数据当作孤儿对象删除。相反，同一站点的多个控制面副本则必须共享完全一致的存储配置。

## 备份和存储清理

数据库备份只包含元数据引用，存储桶或目录备份只包含底层对象字节，恢复时两者必须配套还原。当某个底层 blob 对象在 Agent 云盘、Pod `file` 页面、Pod 文档/Base/Chat 与对话附件以及已编译 Applet 产物包中均不再被引用时，控制面的垃圾回收任务会统一将其清理；请勿在存储桶上额外设置会删除有效对象的自动过期规则。

S3 后端写入大文件时使用分段上传（Multipart Upload），进程异常中断可能留下未完成的分段。建议为存储桶配置自动中止未完成分段上传的生命周期规则，并根据实际负载设定超时天数。本地文件系统（`fs`）后端会在启动打开存储时清理超过一天未变动的临时文件，但这一机制不能代替数据备份。

排查存储故障时，可先在不启动任何 Worker 的情况下通过 Console 上传、下载已知文件，单独验证控制面存储后端；确认正常后，再启用一个 Worker 验证文件读写与附件发送。遇到 `AccessDenied` 时重点检查工作负载身份与桶权限策略；`fs` 写入失败时检查卷挂载、uid 10001 写权限与磁盘空间；找不到历史文件时先核对桶名、区域、前缀及 `blobs/` 复制结果。还原流程见 [备份与还原](../backup-and-restore/)，1.x 旧版文件导入见 [升级到 2.0](../upgrade-to-2/)。
