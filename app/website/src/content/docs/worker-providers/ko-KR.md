---
title: WorkerProvider와 캐시 디스크
description: Docker, Kubernetes, Cloudflare, Vercel, Lambda, Function Compute의 제한과 Home 및 SQLite 캐시 요구 사항을 비교합니다.
section: Guides
order: 317
---

WorkerProvider는 Agent 컴퓨터의 실행 위치와 Home 및 캐시 저장 방식을 정합니다. Agent마다 고정된 provider와 전용 Worker가 있습니다. provider는 사이트 소유이며 자격 증명은 Console의 별도 필드에 암호화해 저장합니다. 설정 YAML에 키를 넣지 마세요. 생성과 일상 운영은 [Worker](../worker-management/)를 참조하세요.

Vercel은 `vercel-worker-provider` Control Plane Plugin이 필요합니다. Alibaba Function Compute는 모델 어댑터도 제공하는 `china-market-ai-providers`가 필요합니다. 사용 전에 필요한 Plugin을 활성화하고 제어면을 재시작하세요. 기존 배포는 업그레이드 전에 해당 Plugin ID를 선택해야 합니다. 일시 중지되거나 삭제 대기 중인 Agent를 포함하여 Worker provider를 참조하는 Agent가 있으면 Plugin을 비활성화할 수 없습니다.

## 세 가지 저장소

| 저장소 | 내용 | 영속성 |
| --- | --- | --- |
| Agent Home: `/workspace` | 작업 공간, 소프트웨어, `/workspace/.codex` 스레드 | 인스턴스 삭제와 이미지 교체 후 유지하며 백업 필요 |
| Worker 캐시: `/var/cache/ankole` | `codex/`의 SQLite, WAL, 로컬 프로세스 잠금 | 재구축 가능하며 Agent별 전용 |
| 제어면 드라이브 | 첨부, 게시 파일, Skill, Automation 스크립트 | PostgreSQL 참조와 OpenDAL 바이트를 함께 백업 |

드라이브 S3 버킷으로 Home이나 SQLite 캐시를 대체할 수 없습니다. Cloudflare R2 Home 백업과 Function Compute OSS Home도 별도 설정입니다. [드라이브 저장소](../drive-storage/)를 참조하세요.

## Provider 비교

| `kind` | Home | 캐시 | 유휴 작업 | 인스턴스 수명 |
| --- | --- | --- | --- | --- |
| `docker` | 전용 로컬 named volume | 전용 로컬 named volume | 컨테이너 삭제 | adapter의 고정 제한 없음 |
| `kubernetes` | 전용 PVC 또는 공유 PVC의 Agent 디렉터리 | 전용 PVC 또는 `emptyDir` | Pod 삭제 | adapter의 고정 제한 없음 |
| `cloudflare` | 시작 시 R2 복원, 정상 종료 전 백업 | 인스턴스 디스크 | 백업 후 컨테이너 삭제 | 플랫폼에 따름 |
| `vercel` | Agent별 전용 Drive | 인스턴스 디스크 | sandbox 삭제 | 설정 가능, 기본 24시간 |
| `lambda` | EFS의 Agent 디렉터리 | 인스턴스 디스크 | 메모리 보존 일시 중지 | 일시 중지 포함 8시간 |
| `function_compute` | AgenticSpace 또는 OSS Agent prefix | 인스턴스 디스크 | 메모리 보존 일시 중지 | 24시간 |

이는 Ankole adapter가 사용하는 제한이며 플랫폼 전체 사양은 아닙니다. 계정 quota, 요금제, region 가용성도 확인하세요. ACS는 WorkerProvider로 등록되지 않았습니다.

6종 모두 `idleReleaseAfter` 기본값은 `15m`이며 `never`도 가능합니다. 유휴 회수 설정은 플랫폼 수명을 늘리지 않습니다. 위치, 저장 키, provider 유형, 기존 Agent 할당은 바꿀 수 없습니다. 사양, 환경 변수, endpoint 변경은 유휴 Worker를 교체합니다. seed YAML은 provider 테이블이 비었을 때만 가져오며 이후에는 Console에서 수정하세요.

## Provider별 요구 사항

### Docker

- 로컬 Engine과 `local` volume driver를 사용하며 개발 및 단일 호스트에 적합합니다. 교체 시 volume은 유지되지만 호스트 손실 시 Home도 잃습니다. 다른 장비에 백업하세요.
- 제어면에 Docker socket 접근이 필요합니다. Compose `ANKOLE_DOCKER_GID`를 socket 그룹과 맞추세요. 이 접근은 호스트 root 권한과 같습니다.
- `network`에서 제어면과 외부 서비스에 연결할 수 있어야 합니다. capability 또는 security-option 재정의는 허용하지 않습니다.
- Home과 캐시는 별도 volume입니다. 로컬 캐시 volume을 네트워크 파일시스템 mount로 바꾸지 마세요.

### Kubernetes

- `storage.claimTemplate` 또는 `storage.sharedClaim`을 선택하세요. 여러 노드의 공유 Home에는 `ReadWriteMany`가 필요합니다. 전용 블록 저장소는 `ReadWriteOnce` 또는 CSI가 지원하는 `ReadWriteOncePod`를 사용할 수 있습니다. 캐시는 별도 블록 PVC나 `emptyDir`를 쓰세요.
- 신뢰된 Worker 프로세스는 root로 시작하고 모델 명령은 uid 1000으로 실행됩니다. Worker와 저장소 삭제 helper Pod는 baseline Pod Security 허용이 필요하며 restricted 정책을 충족하지 않습니다.
- Home은 root 쓰기와 uid 1000으로의 소유권 변경을 허용하거나 모든 접근을 uid 1000으로 매핑해야 합니다. 이 매핑이 없는 root-squash NFS는 요건을 충족하지 않습니다.
- 제어면에 Pod, Secret, PVC, 삭제 helper용 RBAC가 필요합니다. 원격 kubeconfig는 3개 `endpoints`를 모두 명시해야 하며 로컬 `ownerConfigMap`을 사용할 수 없습니다. 생성 후 in-cluster와 원격 kubeconfig 모드를 바꿀 수 없습니다.
- 새 노드에 Worker 이미지를 미리 pull하세요. 이미지 준비 단계는 Kubernetes pull을 대신하지 않습니다. 정상 Pod 삭제를 기다리고 강제 삭제나 유예 시간 0으로 노드 장애를 우회하지 마세요.

### Cloudflare

- [Cloudflare adapter](https://github.com/AgentBull/ankole/tree/main/tools/deploy/cloudflare/agent-workers)를 먼저 배포하고 Worker 이미지 매핑, R2, 별도의 `adapterToken`을 설정하세요.
- 인스턴스 디스크에 이미지, 복원된 Home, 캐시, 임시 파일이 모두 들어가야 합니다. R2 용량은 디스크를 늘리지 않습니다. `lite`, `standard-1`부터 `standard-4`, 사용자 지정 사양을 허용하지만 [Cloudflare 제한](https://developers.cloudflare.com/containers/platform/limits/)도 충족해야 합니다.
- 정상 회수는 Home을 먼저 백업합니다. 강제 종료는 마지막 백업 이후 쓰기를 잃을 수 있습니다. 백업 실패를 회수 성공으로 처리하지 않습니다. `stopGraceSeconds` 기본값은 300초입니다.
- 현재 공개 file relay는 제어면 복제본 하나가 필요합니다. S3 드라이브로 바꿔도 이 제한은 남습니다.

### Vercel

- 같은 region의 전용 Drive를 Home으로 사용합니다. `teamId`, `projectId`, `region`, `driveSizeGiB`는 생성 후 변경할 수 없습니다.
- 프로젝트 VCR에 `linux/amd64` 이미지를 준비하고 목표 digest를 사용하세요. `cpus`는 1 또는 2~32의 짝수이며 메모리는 vCPU당 2048 MiB입니다.
- `sessionTimeoutSeconds` 기본값은 86400(24시간)입니다. 계정 제한이 45분이면 2700으로 설정하세요. 같은 제한을 반환하는 체험 계정에도 적용됩니다. 계정의 실제 제한을 초과할 수 없습니다. [Vercel 시간 제한](https://vercel.com/kb/guide/vercel-sandbox-duration-and-persistence)을 참고하세요. sandbox를 삭제하면 Drive는 유지되고 인스턴스 캐시는 삭제됩니다.
- 짧은 시작, 파일 유지, 이미지 교체, Drive 삭제는 확인되었습니다. OOM, 호스트 장애, 전체 24시간 수명은 대상 환경에서 검증해야 합니다.

### AWS Lambda MicroVMs

- Lambda MicroVMs를 사용합니다. `arm64` Worker 이미지, 빌드용 S3 버킷과 IAM role, VPC network connector, 연결 가능한 EFS가 필요합니다.
- 공식 이미지는 `memoryMiB: 4096` 또는 `8192`만 허용합니다. 저장된 더 낮은 값은 Console에서 수정해야 실행과 정리를 진행할 수 있습니다. `env`는 최대 47개, `stopGraceSeconds`는 최대 59초입니다.
- 메모리 quota에는 실행 중, 일시 중지 중, 저장소 삭제 helper가 모두 포함됩니다. 일시 중지는 용량을 반환하지 않습니다. 삭제 후에도 AWS의 종료 확인을 기다리세요. [MicroVM quota와 lifecycle](https://docs.aws.amazon.com/lambda/latest/dg/microvms-launching.html)을 참조하세요.
- EFS는 Home, 인스턴스 디스크는 SQLite를 저장합니다. 8시간 제한은 일시 중지도 포함합니다. 이전 빌드 객체와 이미지는 자동 정리하지 않습니다. 빌드 role, 이미지, 네트워크 실패를 고친 후 재시도하세요.
- 짧은 메모리 일시 중지, EFS 유지, 정리는 확인되었습니다. 장시간 일시 중지와 전체 수명은 배포 환경 검증이 필요합니다.

### Alibaba Function Compute

- ACR Enterprise의 `amd64` 이미지로 2세대 template을 빌드합니다. Team, Sandbox API key, POP AccessKey, 허가된 RAM role이 필요합니다. template 캡처에는 Agent 신원이나 자격 증명을 넣지 않습니다.
- `storage.agenticFs` 또는 `storage.oss`를 선택하세요. AgenticFS에는 VPC, filesystem, region/zone, 용량 및 파일 수 quota가 필요합니다. mount 전에 access point가 준비되어야 합니다. [AgenticFS Volume](https://help.aliyun.com/zh/functioncompute/create-an-agenticfs-volume)을 참조하세요.
- 이미지에는 OSSFS2 2.0.10 이상이 필요하며 mount 전 `/workspace`는 비어 있어야 합니다. 공식 Worker 이미지는 이 요건을 충족하며 entry가 mount 후 실행 디렉터리를 만듭니다.
- OSS는 이 Agent의 `<root>/<agent_uid>`만 mount하며 완전한 POSIX 동작을 제공하지 않습니다. SQLite 캐시를 OSS에 두지 마세요. `chown` 실패만으로 쓰기 불가라고 판단하지 마세요.
- provider `env`는 변수를 추가할 수 있지만 이미지에 기록된 변수를 덮어쓸 수 없습니다. pause는 메모리를 보존하며 resume는 새로운 24시간 timeout을 사용합니다. 이전 template은 자동 정리하지 않습니다.
- 재개 시 이미지의 보조 프로그램으로 OSSFS2 연결을 다시 만들고 mount와 열린 파일을 유지합니다. 메모리 일시 중지 중 사용할 수 없게 된 TCP 연결 때문에 읽기가 지연되는 것을 방지합니다. 보조 프로그램이 실패하면 공급자가 해당 인스턴스를 삭제하고, 다음 조정에서 Home으로부터 다시 만듭니다. 이 프로그램이 포함된 Worker 이미지와 해당 컨트롤 플레인 버전을 함께 사용하세요. AgenticFS는 여전히 실제 환경 검증이 필요합니다.

외부 provider와 원격 Kubernetes는 인스턴스에서 접근 가능한 `runtimeFabricUrl`, `relayOrigin`, `aiGatewayUrl`이 필요합니다. 연결할 수 없는 Compose service 이름이나 cluster 내부 전용 주소를 쓰지 마세요.

`endpoints.relayOrigin`을 명시한 provider는 제어면 복제본 하나가 필요합니다. 파일 전송이 relay 소유 노드에 도착해야 하며 공식 Helm은 여러 복제본을 거부합니다. Vercel, Lambda, Function Compute, 원격 Kubernetes에도 적용됩니다.

## 캐시 디스크 요구 사항

SQLite와 프로세스 잠금에는 신뢰할 수 있는 잠금, 공유 메모리, 원자적 파일 작업, uid 1000 읽기·쓰기가 필요합니다. 로컬 SSD, 파일시스템으로 mount한 블록 장치, 노드의 `emptyDir`를 사용하세요. NFS, EFS, SMB, S3/R2/OSS FUSE mount를 Codex SQLite 캐시에 쓰지 마세요. [SQLite WAL](https://www.sqlite.org/wal.html)은 네트워크 파일시스템을 지원하지 않습니다.

Agent마다 전용 캐시 디렉터리 또는 PVC를 쓰세요. 여유 공간, inode, 노드 임시 저장소를 모니터링하세요. 모든 작업에 통용되는 최소 용량 보장은 없습니다. 공식 Helm 캐시 PVC 기본값은 20 GiB이며 실제 로그, 동시 실행, 작업에 맞게 조정하세요.

native Kubernetes provider YAML의 영구 캐시 예시입니다. StorageClass를 실제 환경에 맞게 바꾸세요.

```yaml
cache:
  claimTemplate:
    storageClassName: ebs-gp3
    accessModes: [ReadWriteOnce]
    resources:
      requests:
        storage: 20Gi
```

임시 캐시는 다음처럼 설정합니다.

```yaml
cache:
  sizeLimit: 5Gi
```

이 값은 provider YAML입니다. Helm values는 `worker.cache.type: pvc`, `worker.cache.size`, `worker.cache.storageClass` 또는 `worker.cache.type: emptyDir`를 사용합니다. 두 형식을 섞지 마세요.

Docker 캐시 volume과 Kubernetes 캐시 PVC는 정상 회수, 이미지 변경, 일반 인스턴스 설정 교체 후 유지됩니다. 명시적 재구축은 캐시를 지우며 캐시 설정 변경은 캐시를 교체합니다. `emptyDir`와 외부 provider 디스크는 인스턴스 삭제 시 사라집니다. Home은 유지됩니다. app-server가 실행 중일 때 SQLite, WAL, 잠금 파일을 삭제하지 마세요.

시작 검사는 디렉터리 접근과 기본 읽기·쓰기만 확인하며 네트워크 저장소의 SQLite 잠금을 보장하지 않습니다. 잠금 오류, 디스크 부족, 미바인딩 PVC는 **Workers → Reason**, 플랫폼 이벤트, mount 유형부터 확인하세요. [성능 조정](../performance-tuning/)과 [백업](../backup-and-restore/)을 참조하세요.
