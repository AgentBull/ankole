---
title: 재해 복구
description: Ankole 배포 인스턴스를 손실에서 복구하는 전체적인 형태 — 무엇을 복구할 수 있고 무엇을 복구할 수 없는지, 호스트 간 마이그레이션, 그리고 복구를 실제로 만드는 리허설을 다룹니다.
section: Guides
order: 320
---

같은 배포의 PostgreSQL, 파일 저장소, 영구 Agent Home, 원래 배포 비밀 정보를 함께 복원합니다. 보존할 데이터와 일관된 백업 절차는 [백업 가이드](../backup-and-restore/)를 참조하세요.

## 복구 전

이전 control plane과 Worker가 복원한 Home에 쓸 수 없음을 확인하세요. 연결이 끊겼다고 Worker가 중지된 것은 아닙니다. 일시 중지된 인스턴스와 결과를 모르는 생성 요청도 포함합니다. 미확정 generation과 자격 증명은 PostgreSQL에 보존하고 플랫폼이 확정 결과를 줄 때까지 같은 generation을 사용합니다.

훈련은 격리된 플랫폼 리소스에서 진행하세요. 운영 provider 위치가 남은 데이터베이스 복사본은 운영 인스턴스를 관리할 수 있습니다. provider 간 또는 스토리지 구성 간 자동 마이그레이션은 제공하지 않습니다.

## 복구 절차

1. control plane을 중지한 상태에서 대체 인프라를 준비하고 provider 위치와 영구 스토리지 구성을 유지하세요. 빈 volume이 생성되기 전에 Docker Home을 복원합니다.
2. [백업 및 복원](../backup-and-restore/)의 순서대로 PostgreSQL, 해당 파일 저장소, 모든 Home을 복원하세요. Agent UID, volume 이름, 소유권, 권한을 보존합니다.
3. secret manager에서 원래 `ANKOLE_SECRET_BASE`를 복원하세요. provider 비밀 정보와 미확정 generation 자격 증명을 복호화하는 데 필요합니다. 키를 잃었다면 별도 자격 증명 복구 계획을 먼저 세우세요. provider 자격 증명을 다시 입력하는 것만으로 generation 자격 증명이 복구되지는 않습니다.
4. 다른 시작 정보와 주소를 설정한 뒤 control plane을 시작하고 정상 조정 절차로 실제 플랫폼 상태를 확인하세요. 상태 표시를 바꾸려고 generation이나 인스턴스 참조를 지우지 마세요. 미확정 결과는 `starting` 또는 `deleting`에 남고 원인은 `last_error`에 기록됩니다.
5. Agent를 활성화하세요. 알려진 Home 파일과 드라이브 파일을 읽고 Background Job을 재개하며 실제 Turn을 실행합니다. 트래픽 전환 전에 이전 배포가 계속 중지되어 있는지 확인하세요.

## 복구 범위

PostgreSQL은 영구 작업 상태를, Home은 작업 공간과 Codex 스레드를 복원합니다. SQLite 캐시는 다시 만들 수 있습니다. 백업 이후 쓰기, 프로세스 메모리, 진행 중인 모델 요청은 Home 백업에 포함되지 않습니다.

Docker 호스트를 잃으면 로컬 volume의 외부 백업이 필요합니다. Cloudflare는 R2 백업과 데이터베이스 참조가 모두 필요하며 강제 중지는 마지막 백업 이후 변경을 잃을 수 있습니다. [Worker](../worker-management/)의 제한도 확인하세요.

계획된 호스트 이동에서는 쓰기를 중단하고 마지막 일관된 백업을 만드세요. 훈련은 격리 리소스에서 같은 절차와 사용자 흐름을 검증하고 실제 복구 시점과 소요 시간을 기록합니다. Home이나 암호화 키를 생략한 훈련은 완전한 복구를 증명하지 못합니다.
