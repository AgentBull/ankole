defmodule AnkoleWeb.AIGatewayWebSocketBindingTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AIGateway
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AIGateway.RequestContext
  alias AnkoleWeb.AIGatewayResponsesSocket
  alias AnkoleWeb.AIGatewayTokens

  defmodule UpstreamPlug do
    @moduledoc false

    import Plug.Conn

    def init(opts), do: opts

    def call(%Plug.Conn{method: "GET", request_path: "/v1/responses"} = conn, opts) do
      WebSockAdapter.upgrade(
        conn,
        AnkoleWeb.AIGatewayWebSocketBindingTest.UpstreamSocket,
        %{test_pid: opts[:test_pid]},
        []
      )
    end

    def call(conn, _opts), do: send_resp(conn, 404, "not found")
  end

  defmodule UpstreamSocket do
    @moduledoc false

    @behaviour WebSock

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_in({payload, [opcode: :text]}, state) do
      send(state.test_pid, {:upstream_request, Ankole.JSON.decode!(payload)})

      event = %{
        "type" => "response.created",
        "sequence_number" => 0,
        "response" => %{
          "id" => "resp_binding",
          "object" => "response",
          "status" => "in_progress",
          "output" => [],
          "usage" => %{}
        }
      }

      {:push, {:text, Ankole.JSON.encode!(event)}, state}
    end

    def handle_in(_message, state), do: {:ok, state}

    @impl true
    def handle_info(_message, state), do: {:ok, state}

    @impl true
    def terminate(_reason, _state), do: :ok
  end

  test "the controller binding and request context survive socket initialization", %{conn: conn} do
    %{principal: agent} = agent_fixture()
    assert {:ok, api_key} = AIGatewayTokens.mint_for_agent(agent.uid)

    encoded =
      %{
        "selector" => "openrouter/openai/gpt-5.6-sol",
        "provider_options" => %{"reasoningEffort" => "xhigh"},
        "supports_parallel_tool_calls" => true
      }
      |> Ankole.JSON.encode!()
      |> Base.url_encode64(padding: false)

    conn =
      %{
        conn
        | host: "www.example.com",
          req_headers: [{"host", "www.example.com"} | conn.req_headers]
      }
      |> put_req_header("authorization", "Bearer #{api_key.api_key}")
      |> put_req_header("x-ankole-aigateway-model-binding", encoded)
      |> put_req_header("connection", "Upgrade")
      |> put_req_header("upgrade", "websocket")
      |> put_req_header("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ==")
      |> put_req_header("sec-websocket-version", "13")
      |> get(~p"/api/v1/ai-gateway/responses")

    assert conn.state == :upgraded

    assert_receive {_ref, :upgrade, {:websocket, {AIGatewayResponsesSocket, socket_state, _opts}}}

    assert {:ok, initialized_state} = AIGatewayResponsesSocket.init(socket_state)

    assert initialized_state.codex_model_binding == %{
             "selector" => "openrouter/openai/gpt-5.6-sol",
             "provider_options" => %{"reasoningEffort" => "xhigh"},
             "supports_parallel_tool_calls" => true
           }

    assert initialized_state.request_context["downstream_transport"] == "websocket"
  end

  test "the frozen binding routes a Codex model alias to its provider model" do
    %{principal: agent} = agent_fixture()
    base_url = start_upstream()
    provider_id = "openai-codex-socket-binding"

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: provider_id,
               provider_kind: "openai",
               base_url: base_url,
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               },
               connection_options: %{"upstream_transport" => "websocket"}
             })

    connection_state = %{
      subject_uid: agent.uid,
      subject_type: "agent",
      codex_model_binding: %{
        "selector" => "#{provider_id}/gpt-frozen",
        "provider_options" => %{"reasoningEffort" => "high"},
        "supports_parallel_tool_calls" => false
      },
      request_context: RequestContext.from_headers([], "websocket")
    }

    assert {:ok, initialized_state} = AIGatewayResponsesSocket.init(connection_state)

    request =
      Ankole.JSON.encode!(%{
        "type" => "response.create",
        "model" => "gpt-5.6-sol",
        "input" => [text_message("user", "hello")],
        "store" => false
      })

    assert {:ok, %{active_stream: active_stream}} =
             AIGatewayResponsesSocket.handle_in(
               {request, [opcode: :text]},
               initialized_state
             )

    assert_receive {:upstream_request, upstream_request}
    assert upstream_request["model"] == "gpt-frozen"
    assert upstream_request["reasoning"] == %{"effort" => "high"}

    _ = AIGateway.cancel_response_stream(active_stream.stream)
  end

  test "unknown model selectors keep their routing error" do
    %{principal: agent} = agent_fixture()

    request =
      Ankole.JSON.encode!(%{
        "type" => "response.create",
        "model" => "Missing Model",
        "input" => [text_message("user", "hello")],
        "store" => false
      })

    assert {:push, {:text, pushed}, _state} =
             AIGatewayResponsesSocket.handle_in({request, [opcode: :text]}, %{
               subject_uid: agent.uid,
               subject_type: "agent"
             })

    assert %{
             "type" => "error",
             "status" => 422,
             "error" => %{
               "code" => "unknown_model_selector",
               "message" => "Unknown model selector: Missing Model.",
               "param" => "model"
             }
           } = Ankole.JSON.decode!(pushed)
  end

  test "an unconfigured profile name fails as a caller error, not a server error" do
    %{principal: agent} = agent_fixture()

    request =
      Ankole.JSON.encode!(%{
        "type" => "response.create",
        "model" => "missing-alias",
        "input" => [text_message("user", "hello")],
        "store" => false
      })

    assert {:push, {:text, pushed}, _state} =
             AIGatewayResponsesSocket.handle_in({request, [opcode: :text]}, %{
               subject_uid: agent.uid,
               subject_type: "agent"
             })

    assert %{
             "type" => "error",
             "status" => 422,
             "error" => %{
               "code" => "model_profile_not_configured",
               "param" => "model"
             }
           } = Ankole.JSON.decode!(pushed)
  end

  defp start_upstream do
    server =
      start_supervised!(
        {Bandit,
         plug: {UpstreamPlug, test_pid: self()}, scheme: :http, ip: {127, 0, 0, 1}, port: 0}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    "http://127.0.0.1:#{port}/v1"
  end

  defp text_message(role, text) do
    content_type = if role == "assistant", do: "output_text", else: "input_text"

    %{
      "type" => "message",
      "role" => role,
      "content" => [%{"type" => content_type, "text" => text, "annotations" => []}]
    }
  end
end
