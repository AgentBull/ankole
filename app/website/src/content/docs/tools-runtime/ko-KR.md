---
title: Tool 런타임
description: worker가 turn이 model에 제공하는 tool을 수집하고 schema로 변환하며 dispatch하는 방식 — AgentTool contract, turn별 조립, schema 변환, dispatch 경로.
section: Developer guide
order: 120
---

turn 중에 worker는 model이 호출할 수 있는 tool 집합을 조립하고, 각 tool의 schema를 model이 보는 JSON Schema로 변환하며, model이 만든 각 function call을 해당 tool의 `execute` 함수로 dispatch합니다. 이 페이지는 그 런타임을 설명합니다. `AgentTool` contract, turn별 tool 집합이 조립되는 방식, schema가 수집되는 방식, loop가 호출을 dispatch하는 방식이 그것입니다. 이 문서는 [Agent loop](../agent-loop/)와 [Agent Computer Worker](../agent-computer-worker/)를 기반으로 합니다.

핵심 속성을 먼저 말하면, tool은 **turn마다 조립됩니다**. 각 turn은 computer, web, brain, schedule, background job 및 기타 현재 소스에서 최종 tool 집합을 구성합니다. Agent가 소유한 전역 tool 집합은 없습니다. MCP-backed Skill은 computer command tool과 mcporter를 사용합니다.

## AgentTool 계약

모든 tool은 `AgentTool` interface를 구현합니다. 런타임이 신경 쓰는 필드는 다음과 같습니다.

| 필드 | 타입 | 역할 |
|---|---|---|
| `name` | string | model이 보고 호출하는 tool 이름 |
| `description` | string | tool이 하는 일 — model은 이것을 읽고 호출 여부를 결정합니다 |
| `schema` | Zod schema | `execute`가 실행되기 전에 검증되는 입력 매개변수 |
| `jsonSchema` | JSON Schema(선택) | 생성된 Zod schema 대신 사용되는 라이브 외부 schema |
| `namespace` / `namespaceDescription` | string(선택) | 관련 외부 tool을 하나의 provider namespace 아래로 묶습니다 |
| `deferLoading` | boolean(선택) | 하위 schema를 선택될 때까지 Tool Search 뒤에 유지합니다 |
| `executionMode` | `'parallel' \| 'sequential'` | 같은 응답에서 다른 tool과 함께 실행될 수 있는지 여부 |
| `isReadOnly` / `isDestructive` | boolean | 활동 보고와 안전 검사를 위한 메타데이터 |
| `describeActivity` | function | 검증된 매개변수에서 짧은 사람이 읽을 수 있는 라벨을 만듭니다(진행 상황용) |
| `describeCompletedActivity` | function(선택) | tool이 끝나면 라벨을 결과 요약으로 교체합니다 |
| `execute` | function | tool을 실행합니다. 콘텐츠, 세부 정보, 선택적 presentation 이벤트를 반환하며 turn을 종료할 수 있습니다 |

`execute` 함수가 tool의 실제 작업입니다. 검증된 매개변수(schema가 이미 파싱하고 검사함)와 abort signal을 받아 `AgentToolResult`를 반환합니다. 이는 model이 보는 콘텐츠, 로깅용 구조화된 세부 정보, 선택적 응답 presentation 이벤트, 그리고 actor event를 완료하거나 turn을 종료하는 선택적 플래그로 구성됩니다.

## turn마다 tool 집합이 조립되는 방식

`text_turn.ts`는 각 turn 시작 시 category creator에서 tool을 조합하여 tool 집합을 구성합니다.

```typescript
tools = [
  createTodoTool(...),
  ...createComputerTools({...}),
  ...webTools,
  ...brainTools,
  ...scheduleTools,
  ...backgroundAgentJobTools,
  ...
]
```

각 category creator는 turn의 context(worker 환경, agent의 홈, RPC client, abort signal)로 구성된 하나 이상의 `AgentTool` 객체를 반환하는 함수입니다. 조립은 명시적이고 순서가 있으며, reflection도 auto-discovery도 decorator 스캔도 없습니다. tool이 배열에 있으면 사용 가능하고, 없으면 사용할 수 없습니다.

turn별 조립 덕분에 tool 집합이 동적입니다.

- **Skill 지식**은 Agent의 현재 활성화된 Skill에서 투영됩니다. MCP-backed Skill은 도메인 tool을 선택하고 기존 computer command tool을 사용하여 mcporter를 호출합니다.
- **Web tools**는 worker의 `web_search`/`web_fetch` provider 가용성에서 만들어집니다. profile이 바인딩되지 않으면 tool이 없습니다.
- **Background job tools**는 turn의 context에서 만들어지며, turn이 job 생성을 지원할 때만 사용할 수 있습니다.

최종 tool 집합은 여전히 turn별 결과이지, Agent 기능 데이터베이스나 준비된 연결 풀이 아닙니다.

## Schema 수집

model은 Zod가 아닌 JSON Schema가 필요합니다. `tool-schema.ts`는 각 tool의 Zod schema를 변환합니다.

```typescript
export function zodToJSONSchema(schema: z.ZodType): JSONObject {
  const jsonSchema = z.toJSONSchema(schema) as JSONObject
  if (jsonSchema.type !== 'object') {
    throw new Error('function tool parameters must use a root object schema')
  }
  return jsonSchema
}
```

수집된 schema(tool당 하나, 여기에 tool 이름과 설명 포함)는 Responses 요청으로 model에 전송됩니다. 구체적인 외부 adapter가 `jsonSchema`를 제공하면 Ankole은 Zod에서 생성하는 대신 해당 schema를 경계에서 변경 없이 전송하며, `minimum`과 `maximum` 같은 제약 조건도 그대로 유지됩니다. 이후의 projection은 별도의 native runtime이 담당합니다. 지연된(deferred) children은 선택될 때까지 Tool Search 뒤에 남습니다.

model이 function call을 반환하면 해당 인수는 JSON 문자열로 도착합니다. `validateToolArguments`는 tool의 Zod schema를 기준으로 문자열을 파싱하며, 잘못된 형태의 인수(잘린 JSON, 코드 fence 안의 JSON, 균형이 맞지 않는 객체)를 위한 제한된 복구 사다리가 있습니다. tool의 `execute`는 원시 model 출력을 절대 받지 않으며, schema로 검증된 매개변수를 받습니다.

## loop가 호출을 dispatch하는 방식

model의 응답에 function-call 항목이 포함되면 agent loop은 다음을 수행합니다.

1. **tool map 구성** — `agentToolMap(tools)`가 배열을 tool 이름을 키로 하는 `Map<string, AgentTool>`로 변환합니다.
2. **인수 검증** — 각 호출의 인수 문자열을 tool의 schema에 대해 파싱하고 검증하며, 필요하면 복구합니다.
3. **실행** — tool의 `execute` 함수가 검증된 매개변수와 abort signal로 실행됩니다. `executionMode: 'parallel'`인 tool은 동시에 실행될 수 있고, sequential tool은 순서대로 실행됩니다.
4. **결과 기록** — `AgentToolResult`가 function-call-output 메시지로 AIGateway에 전송되며, model은 다음 반복에서 이를 봅니다.

loop가 반복을 소유합니다. model을 호출하고, tool을 실행하고, 결과를 기록하며 model이 더 이상 function call을 반환하지 않을 때까지 반복합니다. tool은 언제 실행할지 결정하지 않으며, loop가 model이 요청한 내용에 따라 결정합니다.

## 이 가이드가 다루지 않는 것

이 가이드는 tool 작성 튜토리얼이 아닙니다. 새 tool은 category creator가 반환하는 `AgentTool` 객체이며, 기존 category(`tools/computer/`, `tools/web/`, `tools/brain/`)가 참조 예시입니다. model 행동 가이드도 아닙니다. model이 어떤 tool을 호출하는지는 런타임이 아니라 persona의 영역입니다. 그리고 agent loop 페이지를 대체하지도 않습니다. dispatch 경로는 loop의 일부이며, loop 페이지가 그 맥락입니다.

## 다음 단계

- tool 호출을 dispatch하는 loop는 [Agent loop](../agent-loop/)를 참조하세요.
- tool을 실행하는 Agent Computer Worker는 [Agent Computer Worker](../agent-computer-worker/)를 참조하세요.
- Skill 뒤의 MCP 실행 dependency는 [MCP server 참조](../mcp/)를 참조하세요.
- MCP dependency를 지니는 skill은 [Skill 작성](../writing-a-skill/)을 참조하세요.