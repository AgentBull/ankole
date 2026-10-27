---
title: LLM observability
description: AIGateway の LLM セマンティクスを含むランタイム横断の Agent Turn トレースを、OTLP/HTTP レシーバーへ任意でエクスポートする方法を説明します。
section: User guide
order: 44
---

Ankole は、OpenTelemetry Protocol（OTLP）の HTTP/protobuf 形式を使って OpenTelemetry トレースを外部へエクスポートできます。この機能はデフォルトでは無効になっています。`observability.traces.provider` 設定は、Turn のルートスパンと AIGateway の LLM スパンにどのベンダー向け属性を付与するかを切り替えるためのものであり、AIGateway のモデル Provider や通信トランスポートを変更したり、他の OpenTelemetry スパンをフィルタリングしたりするものではありません。指定できる値は次の 3 つです。`langfuse` を選ぶと Langfuse v4 向けの agent / generation 属性が、`langsmith` を選ぶと LangSmith 互換属性が、`opentelemetry` を選ぶと汎用 OpenTelemetry・`gen_ai.*`・Ankole 固有属性が出力されます。

トレース出力を有効にすると、モデルの入力・出力が記録されるほか、ツールの引数や実行結果が含まれる場合もあります。その際、認証情報、リクエストヘッダー、一般的な呼び出し元メタデータ、暗号化された推論（reasoning）フィールドやツールフィールド、および内部用の `__ankole_*` フィールドは Ankole 側で自動的に除去されます。また、インラインの `data:` メディアはバイト数に置き換えられ、1 MiB を超える入出力ペイロードは省略されます。ただし、業務データが含まれ得ることに変わりはないため、送信先のレシーバーには適切なアクセス制御と保持期間（リテンション）ポリシーを備えた信頼できるシステムを指定してください。

ディスパッチされた各 Agent Turn は 1 つのトレースとして記録されます。ルートスパンとなる `turn <event-type>` は Langfuse 上では agent observation として扱われ、サニタイズ済みのトリガーイベントと最終応答を保持します。Main Agent のツールスパンと AIGateway のレスポンススパンはその子スパンとしてぶら下がり、Background Job の場合はさらに `codex.turn` スパンと Codex ツールスパンも含まれます。一方、Turn コンテキストを持たない直接の AIGateway 呼び出しでは、`ai_gateway.response` がルートスパンになります。なお、Agent Computer からは認証済みの Runtime Fabric RPC レーン経由で protobuf OTLP バッチが転送されるため、レシーバーの認証情報はコントロールプレーン内に留まり Worker 側には渡されません。

## Langfuse を構成する

以下の手順は、[Langfuse OpenTelemetry guide](https://langfuse.com/integrations/native/opentelemetry) および [Langfuse v4 migration checklist](https://langfuse.com/integrations/native/opentelemetry/migration-to-v4) に準拠しています。

1. Langfuse プロジェクトの **Settings → API Keys** から、Public Key（`pk-lf-...`）と Secret Key（`sk-lf-...`）を取得します。
2. **Console → AppConfigure → LLM observability** を開き、Trace Provider で **Langfuse** を選択します。
3. 利用リージョンに対応するベースエンドポイントを入力します。EU は `https://cloud.langfuse.com/api/public/otel`、US は `https://us.cloud.langfuse.com/api/public/otel`、Japan は `https://jp.cloud.langfuse.com/api/public/otel`、HIPAA 環境は `https://hipaa.cloud.langfuse.com/api/public/otel` です。セルフホスト版 Langfuse（3.22.0 以降）を使う場合は `https://<langfuse-host>/api/public/otel` を指定します。
4. 次のコマンドを実行し、改行を含まない Basic 認証用のエンコード文字列を生成します。

   ```bash
   printf '%s' 'pk-lf-...:sk-lf-...' | base64 | tr -d '\n'
   ```

5. 認証ヘッダーを 2 行追加します。1 行目には名前 `Authorization`・値 `Basic <base64-value>` を設定し、2 行目には名前 `x-langfuse-ingestion-version`・値 `4` を設定します。
6. **Trace export** を有効化して保存し、コントロールプレーンを再起動します。
7. 動作確認として、通常の Agent メッセージを 1 通送るか、Background Job を 1 件実行してみます。Langfuse 上に `turn <event-type>` の agent ルート observation が表示されるはずです。Main Agent のトレース配下には `tool <name>` と `ai_gateway.response` の子スパンが並び、各レスポンスの下に `chat <model>` generation が記録されます。Background Job ではこれに加えて `codex.turn` と Codex ツールスパンも表示されます。また、直接の AIGateway リクエストは `ai_gateway.response` をルートとして表示され、Provider ネイティブのコンパクション呼び出しは独立した `compact <model>` generation として表示されます。

エンドポイント欄には末尾の `/v1/traces` を含めないでください。送信時に Ankole が自動で `/v1/traces` を付与し、`application/x-protobuf` として送信します。なお、Langfuse のこのエンドポイントは OTLP/gRPC を受け付けません。`x-langfuse-ingestion-version: 4` ヘッダーを指定することで v4 のリアルタイム取り込みが有効になり、設定したヘッダー類は PostgreSQL に暗号化して保存されます。

Langfuse ではトリガー単位でトレースをグループ化できるよう、Ankole が次のルールで `user.id` を設定します。

- 信頼された人間のユーザーからのダイレクトメッセージ Turn では、`principal:<principal_uid>` を設定します。
- グループ会話の Turn、または送信元 Conversation を持つイベント Turn では、`channel:<conversation_uuid>` を設定します。
- 送信元 Conversation がない場合でも、信頼された人間のユーザーがトリガーした Turn であれば `principal:<principal_uid>` を設定します。
- 信頼された人間のユーザーと送信元 Conversation のいずれもない Turn では、`user.id` を省略します。

Turn に属さない直接の AIGateway リクエストでは、`principal:<authenticated_subject_uid>` が使われます。実行主体の Agent 自身については、`ankole.principal.uid`、`ankole.principal.type`、およびフィルタリング可能なトレースメタデータに記録されます。また、Main Agent の会話または Background Job の Codex セッションに対応する Conversation が、Langfuse 上の session として紐付けられます。

なお、`channel:` プレフィックスは可観測性データの伝送契約の一部であり、その後に続く値は外部チャット基盤のチャネル ID ではなく Ankole の公開 Conversation UUID です。

さらに、コントロールプレーンに任意の環境変数 `ANKOLE_ENV` と `ANKOLE_VERSION` を設定しておくと、各トレースに Langfuse の environment（小文字英数字および `-`・`_`、最大 40 文字）と release 情報が付与されます。

## LangSmith を構成する

この設定手順は、[LangSmith OpenTelemetry guide](https://docs.langchain.com/langsmith/trace-with-opentelemetry) および [LangSmith announcement](https://www.langchain.com/blog/opentelemetry-langsmith) に準拠しています。

1. **Console → AppConfigure → LLM observability** を開き、Trace Provider で **LangSmith** を選択します。
2. 利用リージョンに対応するベースエンドポイントを設定します。GCP US は `https://api.smith.langchain.com/otel`、GCP EU は `https://eu.api.smith.langchain.com/otel`、GCP APAC は `https://apac.api.smith.langchain.com/otel`、AWS US は `https://aws.api.smith.langchain.com/otel`、セルフホスト環境は `https://<langsmith-api-host>/api/v1/otel` です。
3. 認証ヘッダーに `x-api-key` を追加します。必要に応じて `Langsmith-Project` も追加してください（省略した場合は `default` プロジェクトに送信されます）。
4. **Trace export** を有効化して保存し、コントロールプレーンを再起動します。

AIGateway の Response が特定の会話に紐付いている場合、`langsmith` プロバイダーはその会話 ID を LangSmith 公式の `langsmith.trace.session_id` 属性に設定するとともに、`session.id` と `gen_ai.conversation.id` にも同じ値を保持します。

## 他の OTLP/HTTP receiver

以下のレシーバーを利用する場合は、`observability.traces.provider=opentelemetry` を選択します。ここでもベースエンドポイントに `/v1/traces` は付けないでください。
Console のフォーム画面から設定する際は、表の Headers 列にある各キー・値を認証ヘッダーの 1 行ずつとして追加します。

| Receiver | Endpoint | Headers |
|---|---|---|
| OpenTelemetry Collector | `http://<collector-host>:4318` | 認証が不要であれば `{}` |
| VictoriaTraces single-node | `http://<victoria-traces>:10428/insert/opentelemetry` | 信頼されたネットワーク内で認証プロキシを使わない場合は `{}` |
| VictoriaTraces cluster | `http://<vtinsert>:10481/insert/opentelemetry` | 信頼されたネットワーク内で認証プロキシを使わない場合は `{}` |
| Honeycomb US / EU | `https://api.honeycomb.io` / `https://api.eu1.honeycomb.io` | `{"x-honeycomb-team":"<api-key>"}` |
| Grafana Cloud | スタックの OpenTelemetry 接続タイルからベースエンドポイントをコピー | `{"Authorization":"Basic <base64(instance-id:access-policy-token)>"}` |

VictoriaTraces へ送信される最終的なパスは `/insert/opentelemetry/v1/traces` になります。VictoriaTraces 単体にはテナント認可機能がないため、信頼できないネットワークを経由する場合は vmauth などの認証プロキシを前段に配置してください。詳しくは [VictoriaTraces OTLP documentation](https://docs.victoriametrics.com/victoriatraces/data-ingestion/opentelemetry/) を参照してください。

Grafana Cloud のトークンには `traces:write` スコープが必要です。詳しくは [Honeycomb OTLP documentation](https://docs.honeycomb.io/send-data/opentelemetry) および [Grafana Cloud OTLP documentation](https://grafana.com/docs/grafana-cloud/send-data/otlp/send-data-otlp/) を参照してください。なお、Trace Provider の選択によって属性が追加されるのは Turn ルートスパンと AIGateway LLM スパンのみです。Worker のツールスパンやコントロールプレーン内のその他のスパンはベンダー中立のまま、設定された同じレシーバーへ送信されます。

トレース設定の変更は、コントロールプレーンの起動時に 1 回だけ読み込まれます。エクスポートを無効にする場合は、`observability.traces.enabled` を `false` に変更してからコントロールプレーンを再起動してください。また、環境変数の `OTEL_TRACES_EXPORTER` や `OTEL_EXPORTER_OTLP_*` を使って Ankole を設定しないでください。Ankole は OpenTelemetry の起動前および AppConfigure のエンドポイント・ヘッダー適用前にこれらの環境変数を消去し、AppConfigure 側で一元管理します。
