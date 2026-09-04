defmodule AnkoleWeb.OIDCAIGatewayTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.AIGatewayCase, only: [start_upstream_server: 1, start_response_run: 1]
  import AnkoleWeb.AIGatewayControllerTestHelpers, only: [response_sse_events: 3]
  import Ankole.PrincipalsFixtures

  alias Ankole.AIGateway.Conversations
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.AIGateway.StatefulResponses
  alias Ankole.AuthZ
  alias Ankole.OIDC
  alias Ankole.OIDC.Tokens
  alias Ankole.Principals
  alias Ankole.Repo
  alias AnkoleWeb.AIGatewayResponsesSocket

  @origin "https://spa.example.test"
  @redirect_uri "https://spa.example.test/callback"

  test "OIDC Human policy rejects every inference entry before provider resolution", %{conn: conn} do
    fixture = oidc_gateway_fixture("policy-entry")

    requests = [
      {"/api/v1/ai-gateway/responses", %{"model" => "blocked/model", "input" => "hello"}},
      {"/api/v1/ai-gateway/embeddings", %{"model" => "blocked/model", "input" => "hello"}},
      {"/api/v1/ai-gateway/rerank",
       %{"model" => "blocked/model", "query" => "hello", "documents" => ["one"]}},
      {"/api/v1/ai-gateway/web_search", %{"model" => "blocked/model", "query" => "hello"}},
      {"/api/v1/ai-gateway/web_fetch",
       %{"model" => "blocked/model", "urls" => ["https://example.com"]}}
    ]

    for {path, body} <- requests do
      response =
        conn
        |> recycle()
        |> bearer(fixture.access_token)
        |> post(path, body)

      assert %{"error" => %{"code" => "model_not_allowed"}} = json_response(response, 403)
    end
  end

  test "models returns only Client custom aliases", %{conn: conn} do
    provider_id = "oidc-openai-#{System.unique_integer([:positive])}"
    alias_name = "assistant"
    provider_model = "gpt-4o-mini"

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: provider_id,
               provider_kind: "openai",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-test"}]
               }
             })

    fixture =
      oidc_gateway_fixture("models",
        allowed_models: %{
          alias_name => model_alias(provider_id, provider_model, "Client assistant")
        }
      )

    response =
      conn
      |> bearer(fixture.access_token)
      |> get("/api/v1/ai-gateway/models")
      |> json_response(200)

    explicit_selector = "#{provider_id}/#{provider_model}"

    assert [
             %{
               "id" => ^alias_name,
               "name" => ^alias_name,
               "description" => "Client assistant",
               "canonical_slug" => ^explicit_selector
             }
           ] = response["data"]

    refute Enum.any?(response["data"], &(&1["id"] == explicit_selector))
    refute Enum.any?(response["data"], &(&1["id"] == "primary"))
  end

  test "HTTP Responses resolves a Client alias to its configured upstream model", %{conn: conn} do
    test_pid = self()
    provider_model = "gpt-4o-mini"

    base_url =
      start_upstream_server(fn request ->
        send(test_pid, {:oidc_http_upstream_request, request})

        {:json, 200,
         %{
           "id" => "resp_oidc_http",
           "object" => "response",
           "status" => "completed",
           "model" => provider_model,
           "output" => [],
           "usage" => %{}
         }}
      end)

    provider_id = "oidc-http-provider-#{System.unique_integer([:positive])}"

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: provider_id,
               provider_kind: "openai",
               base_url: "#{base_url}/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-test"}]
               }
             })

    fixture =
      oidc_gateway_fixture("http-alias",
        allowed_models: %{
          "assistant" => model_alias(provider_id, provider_model, "Client assistant")
        }
      )

    response =
      conn
      |> bearer(fixture.access_token)
      |> post("/api/v1/ai-gateway/responses", %{
        "model" => "assistant",
        "input" => "hello"
      })

    assert %{"id" => "resp_oidc_http", "status" => "completed"} = json_response(response, 200)
    assert_receive {:oidc_http_upstream_request, %{path: "v1/responses"} = upstream}
    assert upstream.body["model"] == provider_model
  end

  test "Client model, group, scope, enabled state, and Human status change the next request", %{
    conn: conn
  } do
    fixture = oidc_gateway_fixture("live-policy")
    allowed_request = %{"model" => fixture.allowed_model, "input" => "hello", "store" => true}

    # The request passed OIDC policy and reached the existing HTTP store guard.
    response =
      conn
      |> bearer(fixture.access_token)
      |> post("/api/v1/ai-gateway/responses", allowed_request)

    assert %{"error" => %{"code" => "stateful_responses_require_websocket"}} =
             json_response(response, 400)

    assert {:ok, _client} =
             OIDC.update_client(fixture.client.id, %{
               allowed_models: %{"other" => fixture.model_profile}
             })

    response =
      conn
      |> recycle()
      |> bearer(fixture.access_token)
      |> post("/api/v1/ai-gateway/responses", allowed_request)

    assert %{"error" => %{"code" => "model_not_allowed"}} = json_response(response, 403)

    assert {:ok, _client} =
             OIDC.update_client(fixture.client.id, %{allowed_models: fixture.model_aliases})

    assert {:ok, :deleted} =
             AuthZ.remove_principal_from_group(fixture.human.principal.uid, fixture.group.id)

    response =
      conn
      |> recycle()
      |> bearer(fixture.access_token)
      |> post("/api/v1/ai-gateway/responses", allowed_request)

    assert %{"error" => %{"code" => "access_denied"}} = json_response(response, 403)

    assert {:ok, _membership} =
             AuthZ.add_principal_to_group(fixture.human.principal.uid, fixture.group.id)

    assert {:ok, scope_removed} =
             OIDC.update_client(fixture.client.id, %{scopes: ["openid"]})

    assert scope_removed.allowed_group_ids == []
    assert scope_removed.allowed_models == %{}

    response =
      conn
      |> recycle()
      |> bearer(fixture.access_token)
      |> post("/api/v1/ai-gateway/responses", allowed_request)

    assert %{"error" => %{"code" => "access_denied"}} = json_response(response, 403)

    assert {:ok, _client} =
             OIDC.update_client(fixture.client.id, %{
               enabled: false,
               scopes: ["openid", "ai_gateway.write"],
               allowed_group_ids: [fixture.group.id],
               allowed_models: fixture.model_aliases
             })

    response =
      conn
      |> recycle()
      |> bearer(fixture.access_token)
      |> post("/api/v1/ai-gateway/responses", allowed_request)

    assert %{"error" => %{"code" => "access_denied"}} = json_response(response, 403)

    assert {:ok, _client} = OIDC.update_client(fixture.client.id, %{enabled: true})
    assert {:ok, _human} = Principals.disable_principal(fixture.human.principal.uid)

    response =
      conn
      |> recycle()
      |> bearer(fixture.access_token)
      |> post("/api/v1/ai-gateway/responses", allowed_request)

    assert %{"error" => %{"code" => "access_denied"}} = json_response(response, 403)
  end

  test "browser WebSocket accepts the credential subprotocol, echoes only the app protocol, and rechecks policy",
       %{
         conn: conn
       } do
    fixture = oidc_gateway_fixture("websocket")

    conn =
      conn
      |> websocket_conn(fixture.access_token, @origin)
      |> get("/api/v1/ai-gateway/responses")

    assert conn.state == :upgraded
    assert get_resp_header(conn, "sec-websocket-protocol") == ["ankole.responses.v1"]
    refute response_header_contains?(conn, fixture.access_token)

    assert_receive {_ref, :upgrade,
                    {:websocket,
                     {AIGatewayResponsesSocket,
                      %{
                        subject_uid: subject_uid,
                        subject_type: "oidc_human",
                        oidc_grant: %Ankole.OIDC.Grant{} = grant
                      } = socket_state, _opts}}}

    assert subject_uid == fixture.human.principal.uid
    assert grant.access_token == fixture.access_token
    assert grant.client.id == fixture.client.id

    missing_model = Ankole.JSON.encode!(%{"type" => "response.create", "input" => "hello"})

    assert {:push, {:text, missing_model_error}, _state} =
             AIGatewayResponsesSocket.handle_in(
               {missing_model, [opcode: :text]},
               socket_state
             )

    assert %{
             "status" => 400,
             "error" => %{"code" => "missing_model", "param" => "model"}
           } = Ankole.JSON.decode!(missing_model_error)

    prewarm = Ankole.JSON.encode!(%{"type" => "response.create", "generate" => false})

    assert {:push, chunks, next_state} =
             AIGatewayResponsesSocket.handle_in({prewarm, [opcode: :text]}, socket_state)

    assert Enum.any?(text_chunks(chunks), &(&1["type"] == "response.completed"))

    assert {:ok, :deleted} =
             AuthZ.remove_principal_from_group(fixture.human.principal.uid, fixture.group.id)

    assert {:push, {:text, denied}, _state} =
             AIGatewayResponsesSocket.handle_in({prewarm, [opcode: :text]}, next_state)

    assert %{"status" => 403, "error" => %{"code" => "access_denied"}} =
             Ankole.JSON.decode!(denied)
  end

  test "browser WebSocket requires the registered Origin while native Authorization remains valid",
       %{
         conn: conn
       } do
    fixture = oidc_gateway_fixture("websocket-origin")

    missing_origin =
      conn
      |> websocket_conn(fixture.access_token, nil)
      |> get("/api/v1/ai-gateway/responses")

    assert %{"error" => %{"code" => "access_denied"}} = json_response(missing_origin, 403)

    wrong_origin =
      conn
      |> recycle()
      |> websocket_conn(fixture.access_token, "https://other.example.test")
      |> get("/api/v1/ai-gateway/responses")

    assert %{"error" => %{"code" => "origin_not_allowed"}} = json_response(wrong_origin, 403)

    native =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{fixture.access_token}")
      |> put_req_header("sec-websocket-protocol", "ankole.responses.v1")
      |> websocket_upgrade_headers()
      |> get("/api/v1/ai-gateway/responses")

    assert native.state == :upgraded
    assert get_resp_header(native, "sec-websocket-protocol") == ["ankole.responses.v1"]
  end

  test "stored Responses belong to the Human across Clients and remain after Client deletion", %{
    conn: conn
  } do
    fixture = oidc_gateway_fixture("stored-owner")

    second_client =
      create_gateway_client!("stored-owner-second", fixture.group.id, fixture.model_aliases)

    {:ok, second_token} =
      Tokens.mint_access(
        fixture.human.principal.uid,
        second_client.id,
        "openid ai_gateway.write"
      )

    other_human = human_fixture(%{uid: unique_uid("stored-other")})

    assert {:ok, _membership} =
             AuthZ.add_principal_to_group(other_human.principal.uid, fixture.group.id)

    {:ok, other_token} =
      Tokens.mint_access(other_human.principal.uid, second_client.id, "openid ai_gateway.write")

    {:ok, conversation} =
      Conversations.ensure_conversation(fixture.human.principal.uid, "oidc-human-store")

    {:ok, response} =
      start_response_run(%{
        subject_uid: fixture.human.principal.uid,
        conversation_id: conversation.id,
        request_items: [
          %{
            "id" => "msg_oidc_input",
            "type" => "message",
            "status" => "completed",
            "role" => "user",
            "content" => [%{"type" => "input_text", "text" => "hello"}]
          }
        ],
        metadata: %{"model" => fixture.allowed_model, "request_metadata" => %{}}
      })

    {:ok, response} =
      StatefulResponses.commit_complete(
        response,
        [
          %{
            "id" => "msg_oidc_output",
            "type" => "message",
            "status" => "completed",
            "role" => "assistant",
            "content" => [%{"type" => "output_text", "text" => "world", "annotations" => []}]
          }
        ],
        %{
          "usage" => %{
            "input_tokens" => 1,
            "output_tokens" => 1,
            "total_tokens" => 2,
            "input_tokens_details" => %{"cached_tokens" => 0},
            "output_tokens_details" => %{"reasoning_tokens" => 0}
          }
        }
      )

    response_id = "resp_#{response.id}"

    for token <- [fixture.access_token, second_token.token] do
      retrieved =
        conn
        |> recycle()
        |> bearer(token)
        |> get("/api/v1/ai-gateway/responses/#{response_id}")

      assert json_response(retrieved, 200)["id"] == response_id
    end

    denied =
      conn
      |> recycle()
      |> bearer(other_token.token)
      |> get("/api/v1/ai-gateway/responses/#{response_id}")

    assert %{"error" => %{"code" => "not_found"}} = json_response(denied, 404)

    assert {:ok, _deleted} = OIDC.delete_client(fixture.client.id)
    assert %Message{} = Repo.get!(Message, response.id)

    retrieved =
      conn
      |> recycle()
      |> bearer(second_token.token)
      |> get("/api/v1/ai-gateway/responses/#{response_id}")

    assert json_response(retrieved, 200)["id"] == response_id
  end

  test "OIDC Human stores and continues a Response over WebSocket through another Client", %{
    conn: conn
  } do
    counter = :atomics.new(1, signed: false)
    test_pid = self()

    base_url =
      start_upstream_server(fn request ->
        attempt = :atomics.add_get(counter, 1, 1)

        send(test_pid, {:oidc_store_upstream_request, attempt, request})

        {:sse, 200,
         response_sse_events("resp_oidc_#{attempt}", "gpt-4o-mini", "answer #{attempt}")}
      end)

    provider_id = "oidc-store-provider-#{System.unique_integer([:positive])}"
    alias_name = "assistant"
    provider_model = "gpt-4o-mini"
    model_aliases = %{alias_name => model_alias(provider_id, provider_model, "Stored assistant")}

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: provider_id,
               provider_kind: "openai",
               base_url: "#{base_url}/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-test"}]
               }
             })

    fixture = oidc_gateway_fixture("store-websocket", allowed_models: model_aliases)

    second_client =
      create_gateway_client!("store-websocket-second", fixture.group.id, model_aliases)

    {:ok, second_token} =
      Tokens.mint_access(
        fixture.human.principal.uid,
        second_client.id,
        "openid ai_gateway.write"
      )

    {:ok, first_grant} = Ankole.OIDC.Grant.authorize(fixture.access_token, nil)

    first_state = %{
      subject_uid: fixture.human.principal.uid,
      subject_type: "oidc_human",
      oidc_grant: first_grant
    }

    first_request =
      Ankole.JSON.encode!(%{
        "type" => "response.create",
        "model" => alias_name,
        "input" => "first turn",
        "store" => true
      })

    assert {:ok, %{active_stream: _stream} = first_state} =
             AIGatewayResponsesSocket.handle_in(
               {first_request, [opcode: :text]},
               first_state
             )

    _first_state = drain_response_stream(first_state)

    assert_receive {:oidc_store_upstream_request, 1, %{path: "v1/responses"} = first_upstream}
    assert first_upstream.body["model"] == provider_model

    [first] = completed_subject_responses(fixture.human.principal.uid)
    assert first.subject_uid == fixture.human.principal.uid

    {:ok, second_grant} = Ankole.OIDC.Grant.authorize(second_token.token, nil)

    second_state = %{
      subject_uid: fixture.human.principal.uid,
      subject_type: "oidc_human",
      oidc_grant: second_grant
    }

    second_request =
      Ankole.JSON.encode!(%{
        "type" => "response.create",
        "model" => alias_name,
        "input" => "second turn",
        "previous_response_id" => "resp_#{first.id}",
        "store" => true
      })

    assert {:ok, %{active_stream: _stream} = second_state} =
             AIGatewayResponsesSocket.handle_in(
               {second_request, [opcode: :text]},
               second_state
             )

    _second_state = drain_response_stream(second_state)

    assert_receive {:oidc_store_upstream_request, 2, %{path: "v1/responses"} = second_upstream}
    assert second_upstream.body["model"] == provider_model

    assert [^first, second] = completed_subject_responses(fixture.human.principal.uid)
    assert second.previous_message_id == first.id

    retrieved =
      conn
      |> bearer(second_token.token)
      |> get("/api/v1/ai-gateway/responses/resp_#{second.id}")

    assert json_response(retrieved, 200)["id"] == "resp_#{second.id}"
  end

  test "tampered OIDC token is rejected as invalid", %{conn: conn} do
    fixture = oidc_gateway_fixture("invalid-token")
    tampered = fixture.access_token <> "x"

    response =
      conn
      |> bearer(tampered)
      |> get("/api/v1/ai-gateway/models")

    assert %{"error" => %{"code" => "invalid_token"}} = json_response(response, 401)
  end

  defp oidc_gateway_fixture(prefix, opts \\ []) do
    human = human_fixture(%{uid: unique_uid("#{prefix}-human")})

    {:ok, group} =
      AuthZ.create_principal_group(%{
        name: "#{prefix}-#{System.unique_integer([:positive])}",
        display_name: "#{prefix} users",
        kind: "static"
      })

    assert {:ok, _membership} = AuthZ.add_principal_to_group(human.principal.uid, group.id)

    allowed_models =
      case Keyword.fetch(opts, :allowed_models) do
        {:ok, aliases} ->
          aliases

        :error ->
          provider_id = create_provider!(prefix)
          alias_name = "#{prefix}-chat"
          %{alias_name => model_alias(provider_id, "model", "#{prefix} model")}
      end

    allowed_model = allowed_models |> Map.keys() |> Enum.sort() |> hd()

    client =
      create_gateway_client!(
        prefix,
        group.id,
        allowed_models
      )

    {:ok, token} =
      Tokens.mint_access(human.principal.uid, client.id, "openid ai_gateway.write")

    %{
      access_token: token.token,
      allowed_model: allowed_model,
      model_aliases: allowed_models,
      model_profile: Map.fetch!(allowed_models, allowed_model),
      client: client,
      group: group,
      human: human
    }
  end

  defp create_gateway_client!(prefix, group_id, allowed_models) do
    {:ok, %{client: client}} =
      OIDC.create_client(%{
        name: "#{prefix} Client",
        enabled: true,
        type: "public",
        redirect_uris: [@redirect_uri],
        scopes: ["openid", "ai_gateway.write"],
        allowed_group_ids: [group_id],
        allowed_models: allowed_models
      })

    client
  end

  defp create_provider!(prefix) do
    provider_id = "#{prefix}-provider-#{System.unique_integer([:positive])}"

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: provider_id,
               provider_kind: "openai",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-test"}]
               }
             })

    provider_id
  end

  defp model_alias(provider_id, model, description) do
    %{
      "provider_id" => provider_id,
      "model" => model,
      "description" => description,
      "provider_options" => %{}
    }
  end

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")

  defp websocket_conn(conn, token, origin) do
    encoded = Base.url_encode64(token, padding: false)

    conn =
      conn
      |> put_req_header(
        "sec-websocket-protocol",
        "ankole.responses.v1, base64url.bearer.phx.#{encoded}"
      )
      |> websocket_upgrade_headers()

    if is_binary(origin), do: put_req_header(conn, "origin", origin), else: conn
  end

  defp websocket_upgrade_headers(conn) do
    %{
      conn
      | host: "www.example.com",
        req_headers: [{"host", "www.example.com"} | conn.req_headers]
    }
    |> put_req_header("connection", "Upgrade")
    |> put_req_header("upgrade", "websocket")
    |> put_req_header("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ==")
    |> put_req_header("sec-websocket-version", "13")
  end

  defp response_header_contains?(conn, value) do
    Enum.any?(conn.resp_headers, fn {_name, header_value} ->
      String.contains?(header_value, value)
    end)
  end

  defp text_chunks({:text, chunk}), do: [Ankole.JSON.decode!(chunk)]

  defp text_chunks(chunks) when is_list(chunks) do
    Enum.map(chunks, fn {:text, chunk} -> Ankole.JSON.decode!(chunk) end)
  end

  defp drain_response_stream(%{active_stream: _active_stream} = state) do
    receive do
      {:ai_gateway_response_stream, _ref, :events, _events, _status} = message ->
        case AIGatewayResponsesSocket.handle_info(message, state) do
          {:push, _frames, next_state} -> drain_response_stream(next_state)
          {:ok, next_state} -> drain_response_stream(next_state)
        end
    after
      5_000 -> flunk("OIDC Response stream did not reach a terminal event")
    end
  end

  defp drain_response_stream(state), do: state

  defp completed_subject_responses(subject_uid) do
    Message
    |> Repo.all()
    |> Enum.filter(&(&1.subject_uid == subject_uid and &1.status == "complete"))
    |> Enum.sort_by(&{DateTime.to_unix(&1.inserted_at, :microsecond), &1.id})
  end
end
