---
title: Agent가 이미지를 읽을 수 있도록 하기
description: Agent의 이미지 이해를 구성하고 채팅에서 스크린샷, 사진, 차트를 확인합니다.
section: User guide
order: 42
---

사용자는 채팅에서 Agent에 스크린샷, 사진 또는 차트를 보낼 수 있다. 기본 turn model이 이미지를 받을 수 없는 경우 Ankole은 `vision_fallback` 프로파일의 model을 사용하여 이미지를 읽습니다.

`primary`가 이미 이미지 입력을 지원하면 이 프로파일을 비워 둘 수 있다. 이미지를 전혀 받지 않는 Agent의 경우에도 비워 둘 수 있다.

## 이미지 model 구성

1. **Console → Agents**를 열고 Agent를 선택합니다.
2. **Model profiles**에서 `vision_fallback`을 찾습니다.
3. 이미지 입력을 명시적으로 지원하는 Provider와 model을 선택합니다.
4. 프로파일을 저장한 다음 새 대화를 시작합니다.

model 목록이 이미지 지원 여부를 결정해 주지는 않습니다. model을 선택하기 전에 Provider 문서를 확인합니다.

## 구성 확인

Agent와 연결된 채팅에서 선명한 이미지를 보냅니다. 이미지가 필요한 질문을 한다. 예를 들어:

> 이 스크린샷에는 어떤 오류가 표시되나? 가장 유력한 원인을 알려 줘.

Agent가 이미지를 무시하거나 읽을 수 없다고 말하면 다음 항목을 순서대로 확인합니다:

1. 채팅 channel이 이미지를 업로드하고 전달했는지 확인합니다.
2. 올바른 Agent에 `vision_fallback`이 저장되었는지 확인합니다.
3. 선택한 model이 이미지 입력을 지원하는지 확인합니다.
4. Provider credential과 quota를 사용할 수 있는지 확인합니다.

Agent가 이미지를 생성하도록 하려면 [이미지 생성](../image-generation/)을 참조합니다. 이미지 생성과 이미지 이해는 서로 다른 model 프로파일을 사용합니다.
