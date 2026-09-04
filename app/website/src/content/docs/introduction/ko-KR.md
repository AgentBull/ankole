---
title: 소개
description: Ankole의 Agent Harness와 Company Brain이 모델에 컨텍스트, 권한, 실행, 피드백을 제공하는 방식을 설명합니다.
section: Getting started
order: 1
---

**Ankole은 Company Brain을 갖춘 오픈 소스 Claude Tag 대안입니다. 기업용 Agent Harness가 Agent의 판단에 필요한 컨텍스트, 권한, 도구, 피드백을 제공합니다.**

지속해서 실행되는 Agent는 회사 전체 업무에서 공유 지식, 실시간 신호, 기업 권한, Agent Computer 작업 환경, 복구 가능한 장기 실행을 사용합니다.

모델은 추론과 생성을 담당합니다. Harness는 현재 유효한 회사 지식, 접근 권한, 실행 권한, 장애 복구, 결과 피드백을 관리합니다.

## Harness가 제공하는 기능

- Brain은 지식의 출처, 시점, 소유자, 신뢰도, 충돌, 공개 범위를 관리하고 현재 회사 컨텍스트를 제공합니다.
- 판단에는 근거, 불확실성, 경쟁 가설, 누락된 정보가 포함됩니다. 이후 결과로 판단의 품질을 검증할 수 있습니다.
- 메시지, 일정, Webhook, 외부 이벤트가 담당 Agent를 시작합니다.
- ID, AuthZ, 승인 지점, 감사 기록, 에스컬레이션 경로가 Agent의 작업 범위를 정합니다.
- 작업은 수 시간 또는 수일 동안 실행되고 새 입력을 받습니다. 저장된 상태를 사용해 프로세스 장애 후에도 작업을 재개합니다.
- 수정과 결과가 Company Brain을 갱신합니다. 다음 판단은 회사의 최신 지식과 승인된 규칙에서 시작합니다.

## 배포 인스턴스의 구성 요소

다음 용어는 문서 전체에서 같은 의미로 사용합니다.

| 구성 요소 | 설명 | 더 보기 |
|---|---|---|
| **Agent** | 고유한 미션, 접근 권한, 도구, 대외 ID를 가진 작업 주체입니다. 미션과 전달 기준은 편집 가능한 파일에 저장되며, 하나의 배포 인스턴스에서 여러 Agent를 운영할 수 있습니다. | [Agents](../agents/) |
| **Brain** | 회사의 공유 지식 계층입니다. 출처, 결론, 시간, 신뢰도, 충돌, 공개 범위를 관리해 권한이 있는 Agent에 같은 최신 컨텍스트를 제공합니다. | [Brain](../brain/) |
| **Session** | 장기 실행의 단위입니다. 컨텍스트, 워크스페이스 상태, 조정, 취소, 복구가 Session에서 연결됩니다. | [Actor Runtime](../actor-runtime/) |
| **Signal routing rule** | Agent를 신호 소스에 연결하고 해당 소스에서 허용할 작업 범위를 설정합니다. | [Signal routing rules](../signal-bindings/) |
| **Background job** | Session과 분리되어 수 시간 동안 실행할 수 있는 작업입니다. 완료 결과는 작업을 시작한 채널로 전달됩니다. | [Background Agent Jobs](../background-agent-jobs/) |
| **Skill** | 특정 작업을 수행하는 승인된 절차입니다. Agent가 개선을 제안하고 사람이 이후 Session에 적용할 내용을 승인합니다. | [Skills](../skills/) |
| **Principal** | 사람과 Agent를 나타내는 권한 주체입니다. 런타임은 두 유형에 같은 권한 및 감사 규칙을 적용합니다. | [Principal and AuthZ](../principal-authz/) |
| **Agent Computer Worker** | LLM 루프, 도구, 파일, 터미널, 스트리밍 출력을 실행하는 작업 환경입니다. | [Agent Computer Worker](../agent-computer-worker/) |

Agent는 여러 출처를 장시간 조사할 때 [Deep Research](../deep-research-job/)를 사용합니다. 실제 웹 페이지 작업에는 [브라우저 자동화](../browser-automation/)를 사용합니다.

## 지원하는 의사결정 업무

Ankole은 디지털 환경에서 수행하고 근거와 결과로 검증할 수 있는 의사결정 업무에 적합합니다.

경쟁 가설을 다루는 산업 리서치, 시나리오 모델을 사용하는 제품 및 시장 선택, 재현 가능한 방법과 대안적 인과 가설을 포함한 심층 데이터 분석이 그 예입니다.

Harness는 여러 종류의 업무를 지원합니다. 하나의 Agent가 의사결정 전체를 담당할 수 있습니다. 독립된 컨텍스트가 상관된 오류를 줄이는 경우, Workflow가 여러 Agent에 업무를 배분합니다.

회사 지식과 신호가 컨텍스트를 구성합니다. 제한된 권한으로 Agent가 작업을 실행합니다. 근거와 실제 결과가 이후 의사결정을 갱신합니다.

## 현재 상태

Ankole은 프로덕션에서 실행되는 완전한 기업용 Agent Harness입니다. 회사 인프라에 배포할 수 있습니다. Control Plane, Agent Computer Worker, Kernel, Company Brain, 운영자 Console이 하나의 시스템으로 작동합니다.

공개 API의 호환성 계약은 현재 정의 중입니다. 릴리스 사이에 호환되지 않는 변경이 발생할 수 있습니다.

## 다음 단계

로컬 실행 절차는 [빠른 시작](../quickstart/)에서 확인할 수 있습니다. 전체 구조는 [아키텍처 개요](../architecture/)에서 설명합니다.
