---
title: Rust Kernel
description: Elixir Control Plane이 Rustler를 통해 로드하는 네이티브 기능 및 AI 통신 라이브러리.
section: Developer guide
order: 109
---

Rust Kernel은 Control Plane의 네이티브 라이브러리입니다. Elixir가 Rustler를 통해 로드합니다. Bun Worker는 생성된 protobuf 코덱을 사용합니다.

## 네이티브 기능

`app/kernel/src`는 다음 기능을 제공합니다.

- **`common/`**: AEAD 암호화, 키 파생, 인코딩, 해싱, UUIDv7 식별자, JWT 도구, 전화번호 정규화, Reciprocal Rank Fusion, 토큰 수 추정, URL/IP SSRF 검증.
- **`authz/`**: 명시적 스냅샷을 기반으로 한 권한 평가, CEL 검증 및 조건 평가, 리소스 패턴 매칭. Control Plane은 [Principal 및 AuthZ](../principal-authz/)에 설명된 데이터를 제공합니다.
- **`universal_ai_client/`**: 업스트림 HTTP SSE/EventStream 및 WebSocket 통신, 응답 정규화, 다운스트림 JSON 텍스트 청크 인코딩, 수요 크레딧, 취소, 시간 초과.
- **`object_store/`**: 로컬 디렉터리 또는 S3 호환 버킷을 사용하는 파일 서비스 저장소.
- **`page_document/`**: Pod 페이지 XML 트리 검증, Wordgard 변경 집합 적용, UTF-16 diff 계산.
- **`brain_markdoc/`** 및 **`markdown.rs`**: Brain 본문 분석 및 Markdown 파싱.
- **`model_image.rs`**: 모델 이미지 디코딩, 크기 조정 및 변환.
- **`web_proxy.rs`**: Worker Chromium 세션을 위해 해석된 주소 SSRF 검사를 수행하는 루프백 SOCKS5 `CONNECT` 프록시.
- **`signals/`**: 전달된 컨텍스트를 기반으로 한 라우팅 정책 평가.

## 소유권

Control Plane은 영속 상태, 권한 데이터, 공급자 선택, 자격 증명, 도메인 커밋을 소유합니다. Kernel은 준비된 입력을 받으며 PostgreSQL 조회, Agent 스케줄링, Worker socket 소유를 담당하지 않습니다. 프로그래밍 방식 도구 호출(PTC)과 Pod Applet 백엔드 함수를 위한 격리된 TypeScript 실행은 Rust Kernel이 아니라 상태 비저장 `ankole-function-runtime` 서비스에서 수행됩니다.

RuntimeFabric 구조와 프로토콜 버전 10은 `app/kernel/proto/ankole/runtime_fabric/v1/envelope.proto`에서 선언합니다. Elixir는 Protox를, Worker는 protobuf-es를 사용합니다. 양쪽은 전송할 때 선언된 버전을 기록하고 수신할 때 확인합니다. 도메인 수신자는 실행 권한을 확인하며 언어 간 golden fixture는 코덱 일치 여부를 검증합니다.

## 빌드와 통신

Cargo feature `nif`는 `src/nif_exports.rs`를 통해 Elixir Control Plane을 지원하고, `napi`는 `src/napi_exports.rs`를 통해 Worker 브라우저 데몬과 호스트 테스트를 지원합니다. Rustler는 `src/nif_exports.rs`에서 BEAM 값과 오류를 변환합니다. JSON 형태의 값과 바이트 데이터는 이 경계에서 각각의 표현을 유지합니다.

공유 reqwest client는 모든 환경에서 HTTP/1.1과 aws-lc-rs TLS를 사용합니다. 업스트림 WebSocket 호출은 별도 연결을 사용합니다. 공급자 정책과 transcript 커밋은 [AIGateway](../ai-gateway/)가 소유합니다.

Worker 수명 주기와 메시지 라우팅은 [Sessions](../sessions/) 및 [Agent Computer Worker](../agent-computer-worker/)를 참조하세요.
