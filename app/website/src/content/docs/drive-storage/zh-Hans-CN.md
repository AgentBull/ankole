---
title: 控制面云盘与对象存储配置
description: 为 Ankole.ObjectStore（Agent 云盘、Pod file 页面、各类附件与已编译 Applet 产物包）配置本地文件、云存储桶、数据库表、SFTP 或 WebDAV，并说明迁移与备份要求。
section: Guides
order: 318
---

`ANKOLE_FILES_STORE` 配置控制面对象存储（`Ankole.ObjectStore`），统一保存每个 Agent 的云盘（Worker 停止时仍可使用）、Pod `file` 页面、Pod 文档/Base/Chat 与对话附件以及已编译的 Applet 产物包。PostgreSQL 保存路径、权限和内容引用，OpenDAL 后端保存按内容寻址的对象字节。Ankole 支持 `fs`、`s3`、`azblob`、`d1`、`cos`、`postgresql`、`oss`、`tos`、`gcs`、`sftp` 和 `webdav`。

这份配置属于站点启动配置，所有租户共用同一个对象存储。WorkerProvider 的 Home、缓存和 Cloudflare R2 备份另行配置，见 [WorkerProvider 与缓存盘](../worker-providers/)。用户操作见 [文件管理](../file-management/)。

## 选择后端

| 部署 | `ANKOLE_FILES_STORE` | 使用方式 |
| --- | --- | --- |
| 单机或一个控制面副本 | `fs` | 持久卷或本地文件夹 |
| AWS S3 | `s3` | 桶、region 和 AWS 凭据链 |
| Cloudflare R2 | `s3` | S3 API endpoint、region `auto`、R2 凭据 |
| 其他 S3 兼容服务 | `s3` | 服务的 endpoint、签名 region 和凭据，并验证实际兼容性 |

多个控制面副本需要共享远程存储，并使用相同的后端位置和根路径。官方 Helm 在 `files.store: fs` 且副本数大于 1 时拒绝渲染。云盘使用 S3 不改变个别 WorkerProvider 对控制面副本数的限制。

请将 `controlPlane.replicaCount` 设为 `1`，因为定时触发、聊天适配器连接和调度器水合等控制面单例进程运行在单节点上。共享远程存储是多副本的前提条件，但其本身不足以开启多副本。见 [控制面副本说明](https://github.com/AgentBull/ankole/blob/main/tools/deploy/helm/ankole-agent/README.md#control-plane-replicas)。

## 环境变量

| 变量 | 适用后端 | 要求 |
| --- | --- | --- |
| `ANKOLE_FILES_STORE` | 全部 | 生产必填，选择受支持的后端 |
| `ANKOLE_FILES_FS_ROOT` | `fs` | 控制面内可写的绝对路径 |
| `ANKOLE_FILES_S3_BUCKET` | `s3` | 已创建的桶名称 |
| `ANKOLE_FILES_S3_REGION` | `s3` | 必填；AWS 使用桶所在 region，R2 使用 `auto` |
| `ANKOLE_FILES_S3_ENDPOINT` | `s3` | S3 兼容服务的 endpoint；AWS S3 通常不设置 |
| `ANKOLE_FILES_S3_ROOT` | `s3` | 可选的对象键前缀，如 `/ankole/production/` |
| `ANKOLE_FILES_S3_ACCESS_KEY_ID` | `s3` | 可选静态凭据，须与下一项同时设置 |
| `ANKOLE_FILES_S3_SECRET_ACCESS_KEY` | `s3` | 可选静态凭据，须与上一项同时设置 |

没有静态凭据时使用默认 AWS 凭据链，包括配置好的 EKS Pod Identity。凭据和工作负载身份只提供给控制面；Worker 通过 RuntimeFabric 访问自己的云盘，不需要桶密钥。这些变量在启动时读取，修改后重启控制面。不要把 OpenDAL 的其他参数直接当作 Ankole 环境变量。

## 其他 OpenDAL 后端

环境变量采用 `ANKOLE_FILES_<SCHEME>_<FIELD>`，后端名和字段名均为大写。例如，Azure Blob 需要 `ANKOLE_FILES_STORE=azblob`、`ANKOLE_FILES_AZBLOB_CONTAINER` 和 `ANKOLE_FILES_AZBLOB_ENDPOINT`。下表列出 Ankole 开放的字段；必填字段缺失或为空时，启动失败。

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

凭据保存在控制面的部署 Secret 中。GCS 的 `CREDENTIAL` 是经过 Base64 编码的凭据 JSON，`CREDENTIAL_PATH` 指向原始 JSON 文件；未提供显式凭据时，使用上游 Google 凭据链。SFTP 使用控制面镜像中的 `ssh` 客户端，`KEY` 是私钥文件路径。主机校验默认采用 `strict`，需要配置控制面用户的 `~/.ssh/known_hosts`。WebDAV 支持 Basic 凭据或 bearer `TOKEN`。

D1 和 PostgreSQL 需要预先创建存储表。D1 使用 `TEXT` 主键和 `BLOB` 值，PostgreSQL 使用 `TEXT` 主键和 `BYTEA` 值；`TABLE`、`KEY_FIELD` 和 `VALUE_FIELD` 指定对应名称。Ankole 不创建这张表。D1、PostgreSQL 和 WebDAV 的原生后端会缓冲整份对象。D1 的[字符串、BLOB 和行大小上限为 2,000,000 字节](https://developers.cloudflare.com/d1/platform/limits/)，Ankole 不跨行拆分对象。大文件应使用存储桶后端。

SFTP 先写入对象旁边的临时文件，关闭后重命名。服务端必须支持原子替换，例如 OpenSSH 的 `posix-rename`。控制面进程中途停止后，可能留下 `blobs/<digest>.<uuid>.tmp`；在所有写入进程停止的维护窗口中清理这些文件。

Helm 使用 `files.store` 选择后端；普通变量放在 `controlPlane.extraEnv`，凭据变量放在 `secrets.existingSecret`。Chart 将这个 Secret 注入控制面和迁移容器的环境；同一 Secret 的文件在控制面容器中只读挂载到 `/etc/ankole/bootstrap`。SFTP 私钥权限和 `known_hosts` 必须允许 uid 10001 使用。Compose 沿用下方 override 方法，将所选后端的变量同时传给两个服务。部署前验证读取、写入、替换、删除和大文件传输。

## 本地文件夹与持久卷

```dotenv
ANKOLE_FILES_STORE=fs
ANKOLE_FILES_FS_ROOT=/var/lib/ankole/files
```

路径是控制面进程看到的路径。容器内必须挂载持久存储，否则删除容器会丢失文件。控制面镜像以 uid/gid 10001 运行，该用户需要在目录中创建、写入、重命名和删除文件；`fs` 还会在根目录下创建 `.tmp`。

官方 Compose 已将 `files_data` 卷挂到 `/var/lib/ankole/files`。如果使用宿主文件夹，先创建文件夹并赋予 uid/gid 10001 写权限，再在 Compose override 中替换挂载：

```yaml
services:
  control-plane:
    volumes:
      - ./ankole-files:/var/lib/ankole/files
```

已有站点应先复制原文件存储的内容，不能直接把空文件夹挂到同一路径。旧卷不会因挂载替换而自动迁入新文件夹。

Helm 的本地存储配置：

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

Chart 创建或接管文件 PVC，挂载到 `/var/lib/ankole/files`，并在卸载时保留由 Chart 创建的 PVC。现有 PVC 仍需满足权限和备份要求。这个 PVC 保存云盘，Agent Home 使用另一套存储。

## AWS S3

先创建私有桶，配置允许控制面读取、写入、删除对象及使用 multipart upload 的身份。权限需覆盖桶内所选前缀；若使用 KMS 加密，还要提供配套的 KMS 权限。

```dotenv
ANKOLE_FILES_STORE=s3
ANKOLE_FILES_S3_BUCKET=ankole-files
ANKOLE_FILES_S3_REGION=ap-southeast-1
ANKOLE_FILES_S3_ROOT=/ankole/production/
```

AWS 工作负载身份可省略 Ankole 静态凭据变量。使用静态凭据时，在部署 Secret 中同时提供 `ANKOLE_FILES_S3_ACCESS_KEY_ID` 与 `ANKOLE_FILES_S3_SECRET_ACCESS_KEY`。

Helm 示例：

```yaml
files:
  store: s3
  s3:
    bucket: ankole-files
    region: ap-southeast-1
    root: /ankole/production/
```

可通过 `secrets.existingSecret` 引用包含上述两项 S3 凭据的 bootstrap Secret；这个 Secret 还必须包含部署所需的数据库凭据（`DATABASE_URL`，以及启用内置 PostgreSQL 时的 `POSTGRES_PASSWORD`）、原 `ANKOLE_SECRET_BASE`、`ANKOLE_FUNCTION_RUNTIME_TOKEN` 与 `RELEASE_COOKIE`。Chart 也支持 `secrets.filesS3AccessKeyID` 和 `secrets.filesS3SecretAccessKey`，不要把真实密钥提交到 values 文件。

## Cloudflare R2 与其他 S3 兼容服务

R2 示例沿用 `s3` 后端：

```dotenv
ANKOLE_FILES_STORE=s3
ANKOLE_FILES_S3_BUCKET=ankole-files
ANKOLE_FILES_S3_REGION=auto
ANKOLE_FILES_S3_ENDPOINT=https://ACCOUNT_ID.r2.cloudflarestorage.com
ANKOLE_FILES_S3_ROOT=/ankole/production/
ANKOLE_FILES_S3_ACCESS_KEY_ID=YOUR_R2_ACCESS_KEY_ID
ANKOLE_FILES_S3_SECRET_ACCESS_KEY=YOUR_R2_SECRET_ACCESS_KEY
```

使用 R2 的 S3 API 凭据，endpoint 为账户级 S3 API 地址，不是公开桶域名或 Worker URL。region `auto` 与支持的操作见 [R2 S3 API 兼容说明](https://developers.cloudflare.com/r2/api/s3/api/)。Helm 对应设置 `files.s3.endpoint`、`files.s3.region` 和 `files.s3.root`。

MinIO 等服务也使用 `s3`，填写实际 endpoint 与签名 region。只声明 S3 兼容还不足以确认可用；部署前验证读取、写入、删除、multipart upload 与大文件传输。Ankole 开放本页列出的后端和启动字段；不支持 S3 虚拟主机寻址和自定义签名参数。OpenDAL 参数说明见 [S3 后端](https://opendal.apache.org/docs/rust/opendal/services/struct.S3.html)。

## Compose 使用 S3

官方 Compose 在 YAML 中将后端固定为 `fs`；仅在 `.env` 添加 `ANKOLE_FILES_STORE=s3` 不会覆盖它。使用以下 override 文件，例如 `compose.files-s3.yaml`，把同一配置传给迁移服务和控制面。示例采用静态凭据：

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

在 `.env` 或部署环境填入对应值。新站点可按下列命令启动；已有站点先完成下一节的文件迁移：

```sh
docker compose -f compose.yaml -f compose.files-s3.yaml up -d
```

之后的 `run`、`exec`、升级和一次性 Home 导入命令也使用这两个 `-f` 参数，确保写入同一后端。使用 AWS 凭据链时，移除 override 中两项静态凭据要求，并向容器提供实际的工作负载身份。

## 更换后端、桶或前缀

存储切换不会搬运文件。数据库保存内容引用，实际对象键为 `blobs/<完整 SHA-256>`，位于所选根目录或 S3 前缀下。它们不是按 Agent 云盘文件夹命名的普通目录。

1. 停止请求和定时工作，禁用 Agent，等待工作结束；停止 Worker 与全部控制面，防止文件提交和清理继续运行。
2. 一起备份数据库、原对象存储、Home 和密钥。
3. 将原存储的 `blobs/` 完整复制到目标根目录或前缀，保留对象键；从文件系统复制时排除 `.tmp`。不要按逻辑云盘路径重命名对象。
4. 修改全部控制面的配置，确认它们使用同一目标，然后启动并验证已知文件的下载与内容、新文件的上传、Worker 读写和附件发送。
5. 验证通过后恢复工作，保留原存储用于回退。回退若要保留切换后的写入，也必须同步对应对象与数据库引用。

不要让两个独立站点共享同一对象前缀：一个站点的未引用文件清理可能删除另一个站点仍需要的内容。同一站点的副本则必须共享相同配置。

## 备份和存储清理

数据库备份只有引用，桶或文件夹备份只有对象字节，两者必须一起恢复。控制面垃圾回收会统一清理在 Agent 云盘、Pod `file` 页面、Pod 文档/Base/Chat 与对话附件以及已编译 Applet 产物包中均已不再被引用的 blob 对象；不要在存储桶上额外设置会删除仍被站点引用对象的过期规则。

S3 后端使用 multipart upload，进程中断可能留下未完成上传。为桶配置中止未完成 multipart upload 的生命周期规则，按工作负载选择期限。文件系统后端在打开时清理超过一天未变化的临时文件，这不能代替备份。

没有 Worker 运行时，先在 Console 上传、下载已知文件，验证控制面后端；再启用一个 Worker 验证文件访问与附件发送。`AccessDenied` 时检查身份与桶权限；`fs` 写入失败时检查挂载、uid 10001 权限和容量；旧文件找不到时先核对桶、region、前缀和复制结果。恢复步骤见 [备份与还原](../backup-and-restore/)，1.x 的文件导入见 [升级到 2.0](../upgrade-to-2/)。
