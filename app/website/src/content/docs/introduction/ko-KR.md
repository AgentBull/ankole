---
title: 소개
description: Ankole이 무엇인지, 자율 노동이 copilot과 어떻게 다른지, 프라이빗 배포 인스턴스의 구성 요소에 대해 설명합니다.
section: Getting started
order: 1
---

**Ankole은 오픈소스 AI Workforce OS입니다. AI Agent를 비즈니스 기능을 수행하고 결과로 측정되는 자율 노동으로 전환합니다.**

Agent에 투자 리서치 기능, 권한 경계, 도구, 성과 측정 기준을 부여하세요. Agent는 가설을 유지하고, 보고서를 생산하며, 통화를 추적하고, 이후의 결과와 비교합니다.

copilot은 사람이 작업을 소유하므로 다음 프롬프트를 기다립니다. Ankole Agent는 기능 범위 안에서 다음 행동을 소유하며, 승인·예외·책임 경계에서 사람에게 돌아옵니다.

## 자율 노동이 copilot과 어떻게 다른가

- **채팅 페르소나가 아닌 비즈니스 기능.** 각 Agent는 지속적인 책임, 기대 산출물, 운영 컨텍스트, 결과 측정 기준을 가집니다.
- **활동이 아닌 결과.** 작업은 수익, 위험, 순위, 승인율, 단위당 비용처럼 비즈니스에 중요한 숫자로 평가됩니다.
- **다음 단계 제안이 아닌 실행 루프.** Agent는 계획을 세우고, 도구를 사용하고, 후속 작업을 수행하고, 실패에서 복구하며, 결과물을 전달합니다.
- **경계가 있는 권한.** Identity, AuthZ, 승인, 감사 기록, 에스컬레이션 경로가 Agent가 할 수 있는 일을 정의합니다.
- **단일 요청이 아닌 장기 실행 작업.** 세션은 몇 시간 또는 며칠 동안 실행되고, 새 입력을 받고, 실패 후 복구되며, 운영 컨텍스트를 유지합니다.

자율 작업은 최신 컨텍스트에 의존합니다. Ankole은 모든 오래된 메시지를 동등하게 진실로 취급하는 대신, 규칙, 결정, 수정, 결과를 시간과 출처와 함께 기록합니다.

Brain은 오래된 규칙을 폐기하고, 충돌을 해결하며, 예측을 이후의 결과와 비교합니다. 각 실행은 더 정확한 운영 상황 인식에서 시작됩니다.

## 배포 인스턴스의 구성 요소

이 용어들은 이후 문서 전체에서 반복되므로 여기서 한 번 정리합니다.

| 구성 요소 | 설명 | 더 보기 |
|---|---|---|
| **Agent** | 고유한 미션, 접근 권한, 도구, memory, 대외 identity를 가진 작업 identity입니다. 미션과 전달 기준은 언제든 편집할 수 있는 파일이며, 하나의 배포 인스턴스에 여러 개를 둘 수 있습니다. | [Agents](../agents/) |
| **Session** | 장기 실행의 단위이자, 컨텍스트·워크스페이스 상태·steering·취소·복구가 만나는 지점입니다. | [Actor runtime](../actor-runtime/) |
| **Signal routing rule** | Agent를 signal 소스에 연결하고, 그곳에서 할 수 있는 일의 경계를 설정합니다. | [Signal routing rules](../signal-bindings/) |
| **Background job** | 세션 밖으로 보내져 몇 시간 동안 실행될 수 있고, 작업이 시작된 channel로 결과를 전달해 돌아오는 작업입니다. | [Background Agent Jobs](../background-agent-jobs/) |
| **Memory** | channel 규칙과 장기 memory — 경험에서 예측하고 현실로 교정되는 world model입니다. | [Memory](../memory/), [Brain](../brain/) |
| **Skill** | 한 종류의 작업을 수행하는 정착된 방식입니다. Agent가 개선을 제안할 수 있고, 사람이 다음 세션을 위해 승인합니다. | [Skills](../skills/) |
| **Principal** | 사람과 Agent는 같은 종류의 주체이므로, 런타임은 둘 모두에게 권한과 감사를 적용합니다. | [Principal and AuthZ](../principal-authz/) |
| **Agent Computer Worker** | 실행이 일어나는 장소: LLM 루프, 도구, 파일, 터미널 상태, 스트리밍 출력이 모두 여기서 실행됩니다. | [Agent Computer Worker](../agent-computer-worker/) |

Agent는 장기간의 다중 소스 리서치에 [Deep Research](../deep-research-job/), 실제 웹 페이지 작업에 [browser automation](../browser-automation/)을 사용할 수도 있습니다.

## 수행할 수 있는 비즈니스 기능

Ankole은 디지털로 수행할 수 있고, 검사 가능한 산출물을 만들며, 선언된 결과 측정 기준이 있는 작업에 적합합니다.

예를 들어 증분 ROAS로 측정하는 퍼포먼스 마케팅, 위험 조정 수익으로 측정하는 트레이딩, 순위 변동으로 측정하는 SEO, 등록 승인율로 측정하는 특허 출원 절차가 있습니다.

단위는 Agent 수가 아니라 비즈니스 기능입니다. 다중 Agent 조정은 제품의 약속이 아니라 구현 선택입니다.

공통 계약은 다음과 같습니다: **기능을 정의하고, 경계가 있는 권한을 부여하고, Agent가 작업하게 하며, 결과를 평가합니다.**

## 현재 상태

Ankole은 프로덕션에서 실행 중인 완전하고 자체 호스팅 가능한 AI Workforce OS이며, 아직 초기 단계입니다. control plane, Agent Computer Worker, kernel, 운영자 Console이 엔드투엔드로 작동합니다.

공개 API에는 아직 호환성 계약이 없습니다. 계약이 생기기 전까지 릴리스 간에 breaking change가 발생할 수 있습니다.

## 다음 단계

[퀵스타트](../quickstart/)로 로컬에서 실행해 보세요. 먼저 전체 구조를 보려면 [아키텍처 개요](../architecture/)를 읽어 보세요.