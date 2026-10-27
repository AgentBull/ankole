---
title: WorkerProvider와 캐시 디스크
description: Docker, Kubernetes, Cloudflare, Vercel, Lambda, Function Compute의 제한과 Home 및 SQLite 캐시 요구 사항을 비교합니다.
section: Guides
order: 317
---

WorkerProvider는 각 Agent 컴퓨터가 실행될 인프라 위치와 영구 Home 및 로컬 캐시 저장 방식을 결정합니다. 모든 Agent는 고정된 단일 provider와 전용 Worker를 가지며, provider 리소스는 사이트 범위에 속하고 플랫폼 자격 증명은 Console의 별도 암호화 필드에 저장됩니다(YAML 본문 안에 시크릿 키를 직접 적지 마세요). provider 등록과 일상 운영 방법은 [Worker](../worker-management/)를 참조하세요.

Vercel 백엔드를 쓰려면 `vercel-worker-provider` Control Plane Plugin이 필요하고, Alibaba Function Compute를 쓰려면 모델 어댑터도 함께 제공하는 `china-market-ai-providers` 플러그인이 필요합니다. 사용 전에 해당 플러그인을 활성화하고 제어 플레인을 재시작하세요. 일시 중지 상태이거나 삭제 진행 중인 Agent를 포함해 특정 Worker provider를 참조하는 Agent가 하나라도 남아 있는 동안에는 해당 플러그인을 비활성화할 수 없습니다.

## 세 가지 저장소

| 저장소 | 보관 데이터 | 영속성 및 백업 원칙 |
| --- | --- | --- |
| Agent Home (`/workspace`) | 작업 공간 파일, 사용자 설치 패키지, `/workspace/.codex` 스레드 | 인스턴스 삭제 및 이미지 교체 후에도 유지되며 별도 백업 필요 |
| Worker 캐시 (`/var/cache/ankole`) | `codex/` 하위 SQLite DB, WAL, 로컬 프로세스 잠금 파일 | 손실 시 재구축 가능하며 Agent별로 격리 사용 |
| 제어 플레인 드라이브 | 채팅 첨부 파일, 게시된 파일, Skill, Automation 스크립트 | PostgreSQL 메타데이터 참조와 OpenDAL 객체 바이트를 함께 백업 |

제어 플레인 드라이브용 S3 버킷으로 Agent Home이나 SQLite 캐시 디스크를 대신할 수는 없으며, Cloudflare의 R2 Home 백업과 Function Compute의 OSS Home 마운트 역시 드라이브와는 독립된 별도 설정입니다. 드라이브 구성은 [드라이브 저장소](../drive-storage/)를 참조하세요.

## Provider 비교

| `kind` | Home 저장 방식 | 캐시 디스크 | 유휴 시 처리 | 최대 인스턴스 수명 |
| --- | --- | --- | --- | --- |
| `docker` | 전용 로컬 named volume | 전용 로컬 named volume | 컨테이너 삭제 | 어댑터 차원의 고정 제한 없음 |
| `kubernetes` | 전용 PVC 또는 공유 PVC 내 Agent 디렉터리 | 전용 PVC 또는 `emptyDir` | Pod 삭제 | 어댑터 차원의 고정 제한 없음 |
| `cloudflare` | 기동 시 R2에서 복원, 정상 종료 전 백업 | 인스턴스 로컬 디스크 | 백업 완료 후 컨테이너 삭제 | 플랫폼 정책에 따름 |
| `vercel` | Agent별 전용 Drive | 인스턴스 로컬 디스크 | 샌드박스 삭제 | 설정 가능(기본 24시간) |
| `lambda` | EFS 내 Agent 디렉터리 | 인스턴스 로컬 디스크 | 메모리 보존형 일시 중지 | 일시 중지 시간 포함 8시간 |
| `function_compute` | AgenticSpace 또는 OSS Agent prefix | 인스턴스 로컬 디스크 | 메모리 보존형 일시 중지 | 24시간 |

위 표는 Ankole 어댑터가 사용하는 동작 기준이며 각 클라우드 플랫폼의 전체 스펙을 뜻하지는 않으므로, 실제 계정의 할당량(quota)과 요금제, 리전별 지원 여부도 함께 확인하세요.

6개 provider 모두 `idleReleaseAfter` 기본값은 `15m`이며 `never`로 지정할 수도 있지만, 유휴 회수를 끈다고 해서 플랫폼 자체의 최대 인스턴스 수명이 늘어나지는 않습니다. 생성 후에는 리전·위치, 스토리지 키, provider 종류, 기존 Agent의 할당을 바꿀 수 없습니다. 인스턴스 사양이나 환경 변수, 엔드포인트를 수정하면 유휴 상태인 Worker부터 새 설정으로 교체됩니다. 초기 시드 YAML은 데이터베이스의 provider 테이블이 비어 있을 때 한 번만 읽으므로, 이후 변경은 Console에서 직접 수행하세요.

## Provider별 요구 사항

### Docker

- 로컬 Docker Engine과 `local` 볼륨 드라이버를 사용하므로 로컬 개발이나 단일 호스트 배포에 적합합니다. 컨테이너가 교체되어도 볼륨은 남지만 호스트 디스크 자체가 손상되면 Home도 함께 유실되므로 반드시 외부 장비에 백업하세요.
- 제어 플레인 컨테이너에서 Docker 소켓에 접근할 수 있어야 합니다. Compose의 `ANKOLE_DOCKER_GID` 값을 호스트 소켓 그룹 GID와 일치시키세요(이 권한은 호스트 root 권한과 동등합니다).
- 지정한 `network`에서 제어 플레인과 외부 대상 서비스로 연결할 수 있어야 하며, 임의의 Linux capability나 `security-opt` 재정의는 허용되지 않습니다.
- Home 볼륨과 캐시 볼륨은 별도로 생성됩니다. 로컬 캐시 볼륨을 네트워크 파일시스템 마운트로 바꾸지 마세요.

### Kubernetes

- Home 스토리지로 `storage.claimTemplate` 또는 `storage.sharedClaim` 중 하나를 선택합니다. 여러 노드에 걸쳐 공유 PVC를 쓸 때는 `ReadWriteMany`가 필요하고, Agent별 전용 블록 볼륨을 쓸 때는 `ReadWriteOnce`(또는 CSI 드라이버가 지원하는 `ReadWriteOncePod`)를 사용할 수 있습니다. 캐시는 별도의 블록 PVC나 노드 로컬 `emptyDir`로 구성하세요.
- 신뢰된 초기 Worker 엔트리 프로세스는 root로 시작한 뒤 모델이 실행하는 하위 명령을 `uid 1000`으로 내려 실행합니다. 따라서 Worker Pod와 스토리지 삭제용 helper Pod 모두 Kubernetes Pod Security의 `baseline` 수준이 필요하며 `restricted` 정책에서는 동작하지 않습니다.
- Home 파일시스템은 root 쓰기와 `uid 1000`으로의 소유권 변경(`chown`)을 허용하거나, 처음부터 모든 접근을 `uid 1000`으로 매핑해야 합니다. 별도 ID 매핑 없이 기본 root-squash가 걸린 NFS는 이 요건을 충족하지 못합니다.
- 제어 플레인에 Pod, Secret, PVC 및 삭제용 helper 관리를 위한 RBAC 권한이 필요합니다. 원격 클러스터용 kubeconfig를 쓰는 경우에는 세 가지 `endpoints` 주소를 모두 명시해야 하며 로컬 클러스터 전용인 `ownerConfigMap`은 사용할 수 없습니다. 한번 생성한 뒤에는 in-cluster 모드와 원격 kubeconfig 모드를 서로 전환할 수 없습니다.
- 신규 노드에 Worker 이미지를 미리 pull해 두는 것이 좋습니다(이미지 준비 확인 단계가 Kubernetes의 이미지 pull 자체를 대신하지는 않습니다). 장애 발생 시에도 Pod가 정상 종료될 때까지 기다려야 하며, 강제 삭제나 유예 시간 `0` 설정으로 노드 장애를 우회하지 마세요.

### Cloudflare

- 먼저 [Cloudflare adapter](https://github.com/AgentBull/ankole/tree/main/tools/deploy/cloudflare/agent-workers)를 배포하고 Worker 이미지 매핑, R2 버킷, 전용 `adapterToken`을 설정하세요.
- 컨테이너 로컬 디스크 안에 베이스 이미지, R2에서 복원한 Home, 캐시, 작업 중 임시 파일이 모두 들어갈 수 있어야 합니다(R2 버킷 용량이 인스턴스 디스크 크기를 늘려 주지는 않습니다). `lite`, `standard-1`~`standard-4` 및 커스텀 사양을 지정할 수 있으나 [Cloudflare 컨테이너 제한](https://developers.cloudflare.com/containers/platform/limits/) 범위 안에 들어야 합니다.
- 정상 유휴 회수 시에는 Home을 먼저 R2에 백업한 뒤 컨테이너를 종료합니다. 반대로 컨테이너가 강제 종료되면 마지막 백업 이후의 쓰기 내용이 유실될 수 있으며, 백업이 실패하면 회수 성공으로 처리하지 않습니다(`stopGraceSeconds` 기본값은 `300`초).
- 현재 공개 파일 릴레이(file relay) 경로는 제어 플레인 단일 복제본 구성을 요구하며, 드라이브를 S3로 바꾸더라도 이 제약은 동일하게 유지됩니다.

### Vercel

- 동일한 리전의 전용 Drive를 각 Agent의 Home으로 마운트합니다. 생성 후에는 `teamId`, `projectId`, `region`, `driveSizeGiB`를 변경할 수 없습니다.
- 프로젝트 VCR에 `linux/amd64` 이미지를 올리고 정확한 대상 digest를 지정하세요. `cpus`는 `1` 또는 `2`~`32` 사이의 짝수만 허용되며 메모리는 vCPU당 `2048` MiB로 배정됩니다.
- `sessionTimeoutSeconds` 기본값은 `86400`(24시간)입니다. 계정 한도가 45분인 요금제(동일 한도가 적용되는 체험판 계정 포함)에서는 값을 `2700`으로 낮추어 설정해야 하며, 계정의 실제 상한을 넘는 값은 거부됩니다. 자세한 정책은 [Vercel 샌드박스 수명 안내](https://vercel.com/kb/guide/vercel-sandbox-duration-and-persistence)를 참조하세요. 샌드박스가 삭제되어도 전용 Drive는 보존되고 인스턴스 로컬 캐시만 초기화됩니다.

### AWS Lambda MicroVMs

- AWS Lambda MicroVMs 기반에서 동작하며 `arm64` 아키텍처 Worker 이미지, 빌드용 S3 버킷과 IAM 역할, VPC 네트워크 커넥터, 마운트 가능한 EFS가 필요합니다.
- 공식 이미지는 `memoryMiB` 값으로 `4096` 또는 `8192`만 지원합니다. 이보다 작은 값이 저장되어 있다면 Console에서 먼저 수정해야 인스턴스 기동과 스토리지 정리가 진행됩니다. 환경 변수(`env`)는 최대 47개, `stopGraceSeconds`는 최대 59초까지 지정할 수 있습니다.
- 계정의 MicroVM 메모리 할당량에는 현재 실행 중인 Worker뿐 아니라 일시 중지된 Worker와 스토리지 삭제용 helper 인스턴스까지 모두 합산됩니다. 일시 중지 상태에서도 메모리는 반납되지 않으며, 삭제 요청 후에도 AWS 측 종료 확인을 기다려야 합니다. 자세한 내용은 [MicroVM 할당량 및 수명 주기 문서](https://docs.aws.amazon.com/lambda/latest/dg/microvms-launching.html)를 참조하세요.
- 영구 Home은 EFS에, SQLite 캐시는 인스턴스 로컬 디스크에 저장되며 최대 수명 8시간에는 일시 중지된 시간도 포함됩니다. 과거 빌드 아티팩트와 이미지는 자동으로 지워지지 않으므로 별도로 관리하시고, 빌드 역할·이미지·네트워크 오류가 발생하면 원인을 고친 뒤 재시도하세요.

### Alibaba Function Compute

- ACR Enterprise에 올린 `amd64` 이미지로 2세대 샌드박스 템플릿을 빌드합니다. Team 정보, Sandbox API 키, POP AccessKey, 권한이 부여된 RAM 역할이 필요하며, 베이스 템플릿 스냅샷에는 개별 Agent 신원이나 시크릿이 포함되지 않습니다.
- Home 스토리지로 `storage.agenticFs` 또는 `storage.oss` 중 하나를 선택합니다. AgenticFS를 쓸 때는 VPC, 파일시스템 ID, 리전/존, 용량 및 파일 수 쿼터 설정이 필요하며 마운트 전에 access point가 준비되어 있어야 합니다([AgenticFS 볼륨 안내](https://help.aliyun.com/zh/functioncompute/create-an-agenticfs-volume) 참조).
- 컨테이너 이미지에는 OSSFS2 `2.0.10` 이상이 설치되어 있어야 하고 마운트 전 `/workspace` 디렉터리가 비어 있어야 합니다. 공식 Worker 이미지는 이 조건을 기본 충족하며, 마운트 완료 후 엔트리포인트가 하위 실행 디렉터리를 생성합니다.
- OSS 모드는 해당 Agent 전용 경로인 `<root>/<agent_uid>`만 마운트하며 완전한 POSIX 파일시스템 시맨틱을 보장하지는 않습니다. 따라서 SQLite 캐시를 절대 OSS 경로에 두지 마시고, `chown` 미지원 오류만 보고 쓰기 권한이 없다고 오판하지 마세요.
- provider 설정의 `env`로 새 환경 변수를 추가할 수는 있지만 이미지 빌드 시 이미 박혀 있는 환경 변수를 덮어쓸 수는 없습니다. 일시 중지(pause) 시 메모리가 보존되며 재개(resume)하면 24시간 타임아웃이 새로 부여됩니다. 이전 버전 템플릿은 자동 삭제되지 않습니다.
- 일시 중지에서 깨어날 때는 이미지에 내장된 보조 프로그램이 기존 마운트와 열린 파일 핸들을 유지한 채 끊어진 OSSFS2 TCP 연결을 다시 맺어 읽기 지연을 방지합니다. 만약 재연결 도우미 실행이 실패하면 해당 인스턴스를 폐기하고 다음 조정 주기에서 영구 Home으로부터 새 인스턴스를 띄웁니다. 반드시 이 도우미가 포함된 동일 버전의 Worker 이미지와 제어 플레인을 함께 배포하세요.

클라우드 외부 provider들과 원격 Kubernetes 클러스터를 사용할 때는 Worker 인스턴스 안에서 실제로 접근할 수 있는 `runtimeFabricUrl`, `relayOrigin`, `aiGatewayUrl` 주소를 지정해야 합니다. 외부에서 도달할 수 없는 로컬 Docker Compose 서비스 이름이나 클러스터 내부 전용 DNS 주소를 넣지 마세요.

또한 `endpoints.relayOrigin`을 명시하는 provider(Vercel, Lambda, Function Compute, 원격 Kubernetes 포함)는 현재 제어 플레인 단일 복제본 구성이 필요합니다. 파일 전송 스트림이 릴레이 세션을 보유한 동일한 제어 플레인 노드로 들어와야 하기 때문이며, 공식 Helm 차트에서도 이 경우 다중 복제본 설정을 거부합니다.

## 캐시 디스크 요구 사항

Codex의 SQLite 데이터베이스와 로컬 프로세스 잠금이 안전하게 동작하려면 신뢰할 수 있는 파일 잠금, 공유 메모리(`shm`), 원자적 파일 교체, `uid 1000` 읽기·쓰기 권한이 보장되어야 합니다. 따라서 로컬 SSD, 파일시스템으로 포맷해 마운트한 블록 스토리지, 또는 노드의 로컬 `emptyDir`을 사용하세요. [SQLite WAL 모드](https://www.sqlite.org/wal.html)는 네트워크 파일시스템 위에서 정합성을 보장하지 않으므로 NFS, EFS, SMB 및 S3/R2/OSS FUSE 마운트를 Codex SQLite 캐시 경로로 사용해서는 안 됩니다.

캐시 디렉터리나 PVC는 반드시 Agent마다 전용으로 분리하고 디스크 여유 공간, inode 사용률, 노드의 임시 스토리지(`ephemeral-storage`) 사용량을 모니터링하세요. 워크로드 성격에 따라 사용량이 달라지므로 모든 환경에 통용되는 고정 최소 용량은 없으며, 공식 Helm 차트의 기본 캐시 PVC 크기인 `20 GiB`를 출발점으로 삼아 로그량과 동시 실행 규모에 맞게 조절하세요.

네이티브 Kubernetes provider YAML에서 블록 PVC로 영구 캐시를 구성하는 예시는 다음과 같습니다(`storageClassName`은 클러스터 환경에 맞게 변경).

```yaml
cache:
  claimTemplate:
    storageClassName: ebs-gp3
    accessModes: [ReadWriteOnce]
    resources:
      requests:
        storage: 20Gi
```

노드 로컬 임시 캐시(`emptyDir`)를 쓸 때는 다음과 같이 용량 한도를 지정합니다.

```yaml
cache:
  sizeLimit: 5Gi
```

위 스니펫은 Console에 입력하는 provider YAML 문법입니다. 반면 Helm `values.yaml`에서는 `worker.cache.type: pvc`, `worker.cache.size`, `worker.cache.storageClass` 또는 `worker.cache.type: emptyDir` 키를 사용하므로 두 형식을 혼동하지 마세요.

Docker 캐시 볼륨과 Kubernetes 캐시 PVC는 정상 유휴 회수나 이미지 업데이트, 일반 사양 변경 후에도 그대로 유지됩니다. 운영자가 명시적으로 재구축을 실행하면 캐시 내용이 지워지고, 캐시 스토리지 설정 자체를 바꾸면 새 캐시 볼륨으로 교체됩니다. 반면 `emptyDir`과 클라우드 샌드박스의 인스턴스 로컬 디스크는 인스턴스가 내려갈 때 함께 초기화되지만 영구 Home은 그대로 보존됩니다. Codex `app-server`가 실행 중인 동안에는 SQLite 본체나 WAL, 잠금 파일을 수동으로 삭제하지 마세요.

Worker 기동 시 수행하는 자체 점검은 디렉터리 접근 권한과 기본 읽기·쓰기 동작만 확인할 뿐, 네트워크 스토리지 위의 SQLite 잠금 안전성까지 검증해 주지는 않습니다. 잠금 오류나 디스크 공간 부족, PVC 바인딩 대기 문제가 발생하면 **Workers → Reason**, 플랫폼 이벤트 로그, 마운트된 스토리지 종류부터 확인하세요. 관련 운영 지침은 [성능 조정](../performance-tuning/)과 [백업](../backup-and-restore/)을 참조하세요.
