---
title: Rust Kernel
description: Elixir Control Plane이 Rustler를 통해 로드하는 네이티브 기능 및 AI 통신 라이브러리.
section: Developer guide
order: 109
---

Rust Kernel은 Elixir Control Plane이 Rustler를 통해 로드하는 네이티브 라이브러리이며, Bun Worker는 여기서 생성된 protobuf 코덱을 사용합니다.

## 네이티브 기능

`app/kernel/src`는 다음 모듈로 구성됩니다.

- **`common/`**: AEAD 암호화, 키 파생, 인코딩, 해싱, UUIDv7 식별자, JWT 도구, 전화번호 정규화, Reciprocal Rank Fusion, 토큰 수 추정, URL/IP SSRF 검증을 제공합니다.
- **`authz/`**: 명시적 스냅샷 기반의 권한 평가, CEL 문법 검증 및 조건 평가, 리소스 패턴 매칭을 수행합니다. 평가에 필요한 입력 데이터는 [Principal 및 AuthZ](../principal-authz/)에 설명된 대로 Control Plane이 조립해 전달합니다.
- **`universal_ai_client/`**: 업스트림 HTTP SSE/EventStream 및 WebSocket 통신, 응답 정규화, 다운스트림 JSON 텍스트 청크 인코딩, 수요 크레딧(demand credit), 요청 취소, 타임아웃을 처리합니다.
- **`object_store/`**: 로컬 디렉터리 또는 S3 호환 버킷을 백엔드로 사용하는 파일 서비스 저장소를 제공합니다.
- **`page_document/`**: Pod 페이지 XML 트리 검증, Wordgard 변경 집합 적용, UTF-16 diff 계산을 담당합니다.
- **`brain_markdoc/`** 및 **`markdown.rs`**: Brain 본문 분석과 Markdown 파싱을 수행합니다.
- **`model_image.rs`**: 모델 입력용 이미지의 디코딩, 크기 조정, 포맷 변환을 처리합니다.
- **`web_proxy.rs`**: Worker의 Chromium 세션용 루프백 SOCKS5 `CONNECT` 프록시로, 해석된 대상 IP 주소에 대해 SSRF 검사를 수행합니다.
- **`signals/`**: 전달된 컨텍스트를 바탕으로 라우팅 정책을 평가합니다.

## 소유권

영속 상태, 권한 데이터, 공급자 선택, 자격 증명, 도메인 트랜잭션 커밋은 모두 Control Plane이 소유합니다. Kernel은 Control Plane이 준비해 넘긴 입력만 받아 처리하며, PostgreSQL 조회나 Agent 스케줄링, Worker 소켓 관리는 맡지 않습니다. 프로그래밍 방식 도구 호출(PTC)과 Pod Applet 백엔드 함수를 위한 격리된 TypeScript 실행 역시 Rust Kernel이 아니라 무상태 서비스인 `ankole-function-runtime`에서 담당합니다.

RuntimeFabric 메시지 구조와 프로토콜 버전 10은 `app/kernel/proto/ankole/runtime_fabric/v1/envelope.proto`에 선언되어 있습니다. Elixir에서는 Protox를, Worker에서는 protobuf-es를 사용하며, 양쪽 모두 송신할 때 선언된 버전을 기록하고 수신할 때 이를 검증합니다. 실행 권한 검사는 수신 측 도메인 모듈이 수행하고, 언어 간 코덱 일치 여부는 golden fixture로 검증합니다.

## 빌드와 통신

Cargo feature 중 `nif`는 `src/nif_exports.rs`를 통해 Elixir Control Plane 바인딩을 제공하고, `napi`는 `src/napi_exports.rs`를 통해 Worker 브라우저 데몬과 호스트 테스트를 지원합니다. `src/nif_exports.rs`에서는 Rustler가 BEAM 값과 오류를 변환하며, JSON 형태의 값과 원시 바이트 데이터는 이 경계를 지날 때 각각의 표현을 그대로 유지합니다.

공유 reqwest 클라이언트는 모든 환경에서 HTTP/1.1과 aws-lc-rs TLS를 사용하며, 업스트림 WebSocket 호출은 별도 연결을 엽니다. 공급자별 호출 정책과 대화 전사(transcript) 커밋은 [AIGateway](../ai-gateway/)가 담당합니다.

Worker 수명 주기와 메시지 라우팅은 [Sessions](../sessions/) 및 [Agent Computer Worker](../agent-computer-worker/)를 참조하세요.
