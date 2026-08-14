---
title: LLM observability
description: AIGateway LLM semantics を含む optional cross-runtime Agent Turn trace を OTLP/HTTP receiver に export します。
section: User guide
order: 44
---

Ankole は OpenTelemetry trace を OpenTelemetry Protocol (OTLP) HTTP/protobuf で export できます。この機能はデフォルトで無効です。`observability.traces.provider` は Turn root と AIGateway LLM span に追加する vendor attributes を選択します。AIGateway model Provider や transport ではなく、他の OpenTelemetry span を filter しません。`langfuse` は Langfuse v4 agent と generation attributes、`langsmith` は LangSmith compatibility attributes、`opentelemetry` は汎用 OpenTelemetry、`gen_ai.*`、Ankole attributes を出力します。

有効な trace には model input と output が含まれ、tool argument と result が含まれる場合もあります。Ankole は credential、request header、一般的な caller metadata、暗号化された reasoning と tool field、および内部 `__ankole_*` field を削除します。inline `data:` media は byte count に置き換え、1 MiB を超える input または output payload は省略します。それでも receiver は適切な access control と retention policy を持つ trusted system である必要があります。

dispatch された各 Agent Turn は 1 つの trace になります。`turn <event-type>` root span は Langfuse の agent observation で、sanitize された trigger event と final reply を含みます。Main Agent tool span と AIGateway response span はその child です。Background Job には `codex.turn` と Codex tool span も含まれます。Turn context がない直接の AIGateway call は、引き続き `ai_gateway.response` を root にします。Agent Computer は protobuf OTLP batch を authenticated Runtime Fabric RPC lane 経由で送るため、receiver credential は control plane に残ります。

## Langfuse を構成する

以下の手順は [Langfuse OpenTelemetry guide](https://langfuse.com/integrations/native/opentelemetry) と [Langfuse v4 migration checklist](https://langfuse.com/integrations/native/opentelemetry/migration-to-v4) に従います。

1. Langfuse project の **Settings → API Keys** から Public Key (`pk-lf-...`) と Secret Key (`sk-lf-...`) を取得します。
2. **Console → AppConfigure → LLM observability** を開き、Trace Provider で **Langfuse** を選択します。
3. region に対応する base endpoint を入力します。EU は `https://cloud.langfuse.com/api/public/otel`、US は `https://us.cloud.langfuse.com/api/public/otel`、Japan は `https://jp.cloud.langfuse.com/api/public/otel`、HIPAA は `https://hipaa.cloud.langfuse.com/api/public/otel` です。Self-hosted Langfuse 3.22.0 以降では `https://<langfuse-host>/api/public/otel` を使います。
4. 次の command で改行を含まない Basic Auth value を作成します。

   ```bash
   printf '%s' 'pk-lf-...:sk-lf-...' | base64 | tr -d '\n'
   ```

5. 認証 header の行を 2 つ追加します。1 行目は名前を `Authorization`、値を `Basic <base64-value>` にします。2 行目は名前を `x-langfuse-ingestion-version`、値を `4` にします。
6. **Trace export** を有効にして保存し、control plane を再起動します。
7. 通常の Agent message を 1 件送信するか、Background Job を 1 件実行します。Langfuse には `turn <event-type>` agent root observation が表示されます。Main Agent trace には `tool <name>` と `ai_gateway.response` child があり、各 response の下に `chat <model>` generation があります。Background Job には `codex.turn` と Codex tool span もあります。直接の AIGateway request は引き続き `ai_gateway.response` root として表示されます。provider native compaction の呼び出しは独立した `compact <model>` generation として表示されます。

endpoint に `/v1/traces` を含めないでください。Ankole が `/v1/traces` を追加して `application/x-protobuf` を送信します。Langfuse のこの endpoint は OTLP/gRPC を受け付けません。`x-langfuse-ingestion-version: 4` は v4 real-time ingestion を選択します。headers は PostgreSQL に暗号化して保存されます。

Agent Principal は Langfuse user、会話（Main Agent の会話または Background Job の Codex session）は Langfuse session になります。trace metadata には Principal type、内部 caller、client originator がフィルタ可能なキーとして入ります。control plane に任意の `ANKOLE_ENV` と `ANKOLE_VERSION` を設定すると、各 trace に Langfuse environment（小文字英数字と `-`、`_`、最大 40 文字）と release が付きます。

## LangSmith を構成する

この構成は [LangSmith OpenTelemetry guide](https://docs.langchain.com/langsmith/trace-with-opentelemetry) と [LangSmith announcement](https://www.langchain.com/blog/opentelemetry-langsmith) に従います。

1. **Console → AppConfigure → LLM observability** を開き、Trace Provider で **LangSmith** を選択します。
2. region に対応する base endpoint を設定します。GCP US は `https://api.smith.langchain.com/otel`、GCP EU は `https://eu.api.smith.langchain.com/otel`、GCP APAC は `https://apac.api.smith.langchain.com/otel`、AWS US は `https://aws.api.smith.langchain.com/otel`、self-hosted は `https://<langsmith-api-host>/api/v1/otel` です。
3. 認証 header に `x-api-key` を追加します。必要なら `Langsmith-Project` も追加します。省略すると `default` Project を使います。
4. **Trace export** を有効にして保存し、control plane を再起動します。

AIGateway Response が conversation に属する場合、`langsmith` provider は conversation ID を LangSmith 公式の `langsmith.trace.session_id` に設定し、`session.id` と `gen_ai.conversation.id` にも保持します。

## 他の OTLP/HTTP receiver

次の receiver では `observability.traces.provider=opentelemetry` を使います。base endpoint に `/v1/traces` を追加しないでください。
Visual form では、次の Headers 列の各 entry を認証 header の 1 行として追加します。

| Receiver | Endpoint | Headers |
|---|---|---|
| OpenTelemetry Collector | `http://<collector-host>:4318` | authentication が不要なら `{}` |
| VictoriaTraces single-node | `http://<victoria-traces>:10428/insert/opentelemetry` | trusted network で authentication proxy がなければ `{}` |
| VictoriaTraces cluster | `http://<vtinsert>:10481/insert/opentelemetry` | trusted network で authentication proxy がなければ `{}` |
| Honeycomb US / EU | `https://api.honeycomb.io` / `https://api.eu1.honeycomb.io` | `{"x-honeycomb-team":"<api-key>"}` |
| Grafana Cloud | stack の OpenTelemetry connection tile から base endpoint をコピー | `{"Authorization":"Basic <base64(instance-id:access-policy-token)>"}` |

VictoriaTraces への最終 path は `/insert/opentelemetry/v1/traces` です。VictoriaTraces は tenant authorization を提供しないため、untrusted network では vmauth などの authentication proxy を使います。詳細は [VictoriaTraces OTLP documentation](https://docs.victoriametrics.com/victoriatraces/data-ingestion/opentelemetry/) を参照してください。

Grafana Cloud token には `traces:write` が必要です。詳細は [Honeycomb OTLP documentation](https://docs.honeycomb.io/send-data/opentelemetry) と [Grafana Cloud OTLP documentation](https://grafana.com/docs/grafana-cloud/send-data/otlp/send-data-otlp/) を参照してください。Provider の選択は Turn root と AIGateway LLM span だけを enrich します。Worker tool span と control plane の他の span は vendor-neutral のまま、同じ configured receiver に送信されます。

設定変更は control-plane startup 時に一度だけ読み込まれます。無効にするには `observability.traces.enabled` を `false` にして control plane を再起動します。`OTEL_TRACES_EXPORTER` または `OTEL_EXPORTER_OTLP_*` で Ankole を構成しないでください。Ankole は OpenTelemetry の起動前と AppConfigure の endpoint と headers の適用前に、これらの variables を削除します。この exporter は AppConfigure だけが管理します。
