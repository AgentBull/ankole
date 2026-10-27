---
title: 소개
description: Ankole의 Agent Harness와 Company Brain이 모델에 컨텍스트, 권한, 실행, 피드백을 제공하는 방식을 설명합니다.
section: Getting started
order: 1
---

**Ankole은 Company Brain을 갖춘 오픈 소스 Claude Tag 대안입니다. 기업용 Agent Harness가 Agent의 판단에 필요한 컨텍스트, 권한, 도구, 피드백을 제공합니다.**

상시 운영되는 Agent는 공유 지식, Pod 워크스페이스, 실시간 신호, 엔터프라이즈 권한 체계, Agent Computer 작업 환경, 장애 복구형 장기 실행을 바탕으로 전사 업무를 수행합니다.

모델이 추론과 생성을 맡는다면, Harness는 현재 유효한 회사 지식과 접근·실행 권한, 장애 복구, 결과 피드백을 책임집니다.

## Harness가 제공하는 기능

- Brain이 지식의 출처, 시점, 소유자, 신뢰도, 충돌 여부, 공개 범위를 관리하며 최신 회사 컨텍스트를 제공합니다.
- 각 판단에는 근거, 불확실성, 경쟁 가설, 누락된 정보가 함께 기록되므로 나중에 실제 결과와 대조해 판단 품질을 검증할 수 있습니다.
- 메시지, 일정, Webhook, 외부 이벤트가 들어오면 담당 Agent가 작업을 시작합니다.
- ID, AuthZ, 승인 지점, 감사 기록, 에스컬레이션 경로를 통해 Agent가 수행할 수 있는 작업 범위가 엄격히 결정됩니다.
- 작업은 수 시간에서 수일 동안 이어지며 도중에 새로운 입력을 받을 수 있고, 프로세스 장애가 발생하더라도 저장된 상태에서 그대로 재개됩니다.
- 사람의 수정 사항과 실행 결과를 반영해 Company Brain이 갱신되므로, 다음 판단은 항상 최신 조직 지식과 승인된 규칙 위에서 출발합니다.

## 배포 인스턴스의 구성 요소

문서 전반에서 아래 용어는 다음과 같은 의미로 사용합니다.

| 구성 요소 | 설명 | 더 보기 |
|---|---|---|
| **Agent** | 고유한 미션, 접근 권한, 도구, 대외 ID를 가진 작업 주체입니다. 미션과 전달 기준은 편집 가능한 파일로 관리하며, 하나의 배포 인스턴스에서 여러 Agent를 운영할 수 있습니다. | [Agents](../agents/) |
| **Pod** | 사람과 Agent가 계층형 페이지, 실시간 문서, Base 관계형 테이블, Applet, 멀티플레이어 Pod Chat에서 함께 일하는 공유 워크스페이스입니다. | [아키텍처 개요](../architecture/) |
| **Brain** | 회사의 공유 지식 계층입니다. 출처, 결론, 시점, 신뢰도, 충돌, 공개 범위를 관리해 권한이 있는 Agent에 동일한 최신 컨텍스트를 제공합니다. | [Brain](../brain/) |
| **Session** | 장기 실행의 기본 단위입니다. 컨텍스트, 워크스페이스 상태, 방향 조정(steer), 취소, 복구가 모두 Session 단위로 맞물려 동작합니다. | [Sessions](../sessions/) |
| **Signal routing rule** | 신호 소스와 Agent를 연결하고, 해당 소스에서 허용할 작업 범위를 정의합니다. | [Signal routing rules](../signal-bindings/) |
| **Background job** | 메인 Session과 분리되어 수 시간 동안 실행될 수 있는 작업입니다. 완료된 결과는 작업을 시작한 채널로 전달됩니다. | [Background Agent Jobs](../background-agent-jobs/) |
| **Skill** | 특정 유형의 작업을 수행하기 위한 승인된 절차입니다. Agent가 개선안을 제안하면 사람이 검토해 이후 Session에 반영할 내용을 승인합니다. | [Skills](../skills/) |
| **Principal** | 사람과 Agent를 아우르는 권한 주체입니다. 런타임은 두 주체 유형에 동일한 권한 검사와 감사 규칙을 적용합니다. | [Principal and AuthZ](../principal-authz/) |
| **Function Runtime** | 상태 비저장 서비스인 `ankole-function-runtime`으로, 격리 환경에서 TypeScript 프로그램을 실행해 Pod Applet 백엔드 함수와 결정론적 도구 오케스트레이션을 처리합니다. | [아키텍처 개요](../architecture/) |
| **Agent Computer Worker** | 도구 호출, 파일 작업, 터미널, 브라우저, Codex Job이 실행되는 작업 환경입니다. 주 모델 루프는 Control Plane에서 실행됩니다. | [Agent Computer Worker](../agent-computer-worker/) |

여러 출처를 장시간 심층 조사할 때는 [Deep Research](../deep-research-job/)를 사용하고, 실제 웹 페이지를 직접 조작해야 할 때는 [브라우저 자동화](../browser-automation/)를 사용합니다.

## 지원하는 의사결정 업무

Ankole은 디지털 환경에서 수행되며 근거와 실제 결과로 검증할 수 있는 의사결정 업무에 잘 맞습니다.

예를 들어 경쟁 가설을 함께 검증하는 산업 리서치, 시나리오 모델을 활용한 제품·시장 선택, 재현 가능한 분석 절차와 대안적 인과 가설을 다루는 심층 데이터 분석 등에 활용할 수 있습니다.

업무 성격에 따라 실행 구조도 유연하게 구성할 수 있습니다. 단일 Agent가 의사결정 과정 전체를 맡을 수도 있고, 컨텍스트를 분리해 상관된 오류를 줄여야 할 때는 Workflow로 여러 서브에이전트에 작업을 나누어 맡길 수도 있습니다.

회사 지식과 실시간 신호로 컨텍스트가 구성되면 Agent는 부여된 권한 범위 안에서 작업을 실행하고, 그때 축적된 근거와 실제 결과를 바탕으로 이후 의사결정이 갱신됩니다.

## 현재 상태

Ankole은 프로덕션 환경에서 운영되는 엔터프라이즈용 Agent Harness로, 사내 인프라에 직접 배포할 수 있습니다. Control Plane, Pod 워크스페이스, Function Runtime(`ankole-function-runtime`), Agent Computer Worker, Kernel, Company Brain, 운영자용 Console이 하나의 시스템으로 유기적으로 동작합니다. 핵심 코드와 주요 상태 머신에는 정형 검증을 적용하며, 엔드투엔드 테스트를 통해 메시지 라우팅, 장애 복구, 동시 실행, 업그레이드 경로를 검증합니다.

Ankole은 공개 API의 하위 호환성을 보장하지 않으므로, 새 릴리스에 호환되지 않는 변경이 포함될 수 있습니다.

## 다음 단계

로컬에서 바로 실행해 보려면 [빠른 시작](../quickstart/)을 확인하세요. 시스템 전반의 구조는 [아키텍처 개요](../architecture/)에서 자세히 다룹니다.
