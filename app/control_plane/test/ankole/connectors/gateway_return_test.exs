defmodule Ankole.Connectors.GatewayReturnTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures

  alias Ankole.Connectors.{Access, Gateway, OAuth, Store, Tokens}
  alias AnkoleWeb.PodURL

  defmodule Provider do
    import Plug.Conn
    def init(owner), do: owner

    def call(conn, owner) do
      case {conn.method, conn.request_path} do
        {"POST", "/login/oauth/access_token"} ->
          {:ok, body, conn} = read_body(conn)
          send(owner, {:exchange, Torque.decode!(body)})
          json(conn, %{"access_token" => "authorized-token", "scope" => "repo"})

        {"GET", "/user"} ->
          json(conn, %{"id" => 42})
      end
    end

    defp json(conn, body),
      do:
        conn |> put_resp_content_type("application/json") |> send_resp(200, Torque.encode!(body))
  end

  setup do
    human = human_fixture().principal
    admin = human_fixture().principal
    {:ok, _} = Repo.transact(fn -> Ankole.AuthZ.add_pod_admin_in_tx(admin.uid) end)

    agent = agent_fixture(%{type: :personal_assistant, owner_principal_uid: human.uid}).principal
    server = start_supervised!({Bandit, plug: {Provider, self()}, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    {:ok, config} =
      Store.create_auth_config(admin, %{
        "plugin_id" => "github",
        "slug" => "work",
        "auth_scheme" => "oauth2",
        "secret" => %{"client_id" => "return-test", "client_secret" => "secret"},
        "public_metadata" => %{
          "base_url" => "http://127.0.0.1:#{port}",
          "web_url" => "http://127.0.0.1:#{port}"
        }
      })

    %{human: human, admin: admin, agent: agent, config: config}
  end

  test "signed chat calls carry the original conversation through consent and account claiming",
       ctx do
    {conversation, context} = native_context(ctx)
    params = consent_params(context)
    expected_path = PodURL.conversation_path(conversation.id)
    assert params["intent"] == expected_path
    assert params["subject_kind"] == "human"
    assert params["toolkit"] == "github"
    assert params["scopes"] == "repo"

    return_to = "/connectors?" <> URI.encode_query(params)

    assert {:ok, %{authorization_url: authorization_url}} =
             OAuth.begin(ctx.human, %{
               "connection" => params["connection"],
               "scopes" => String.split(params["scopes"]),
               "return_to" => return_to
             })

    state = authorization_url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert {:ok, %{completion_code: code, return_to: returned}} =
             OAuth.callback(%{"state" => state["state"], "code" => "granted-code"})

    assert_received {:exchange, %{"code" => "granted-code"}}
    assert returned == return_to

    assert returned
           |> URI.parse()
           |> Map.fetch!(:query)
           |> URI.decode_query()
           |> Map.fetch!("intent") ==
             expected_path

    assert {:ok, %{external_subject_id: "42"}} = OAuth.claim(ctx.human, code)
    spec = Enum.find(Ankole.Plugins.GitHubAdapter.Connector.tools(), &(&1.name == "repos_get"))

    assert {:ok, %{access_token: "authorized-token", account: %{owner_principal_uid: uid}}} =
             Ankole.Connectors.resolve_call(spec, ctx.agent, "work", nil)

    assert uid == ctx.human.uid
  end

  test "a personal token request returns to the same chat after the Figma binding flow", ctx do
    {:ok, _} =
      Store.create_auth_config(ctx.admin, %{
        "plugin_id" => "figma",
        "slug" => "figma",
        "auth_scheme" => "personal_token",
        "secret" => %{}
      })

    {conversation, context} = native_context(ctx)
    params = consent_params(context, "figma", "get_current_user", %{})
    assert params["intent"] == PodURL.conversation_path(conversation.id)
    assert params["auth_mode"] == "personal_credentials"
  end

  test "external IM calls keep the binding link without inventing a native conversation route",
       ctx do
    binding =
      Ankole.SignalsFixtures.binding_fixture(ctx.agent.uid, "im", :record_only, adapter: "mock")

    {:ok, signal} =
      Repo.transact(fn ->
        {:ok, conversation} =
          Ankole.Conversations.External.observe_conversation_in_tx(
            binding,
            %{
              provider_conversation_id: "external-chat",
              external_kind: :im_dm,
              reply_mode: :entry
            },
            DateTime.utc_now(:microsecond)
          )

        Ankole.Signals.accept_in_tx(%{
          producer: :kernel,
          source: "test://im-consent",
          id: Ankole.Kernel.gen_uuid_v7(),
          type: "test.source",
          data: %{"text" => "Read my repository"},
          target: %{agent_uid: ctx.agent.uid, conversation_id: conversation.id},
          authorization: Ankole.Principals.WorkAccess.from_sender(ctx.human.uid),
          sender: ctx.human.uid,
          reply_route: %{binding_name: binding.name, conversation_id: conversation.id}
        })
      end)

    params = signal |> worker_context(ctx.agent.uid) |> consent_params()
    refute Map.has_key?(params, "intent")
    assert params["connection"] == "work"
  end

  test "signed Applet and automation calls return to their existing page and Job", ctx do
    actor = Ankole.AuthZ.Actor.new(ctx.human)
    {:ok, page} = Ankole.Pod.Pages.create(actor, %{type: "applet"})

    for {job, suffix} <- [{nil, ""}, {%{"id" => 42}, "?automation_job=42"}] do
      {:ok, headers} =
        Tokens.invocation(
          %{"applet" => %{"pageId" => page.id}, "job" => job},
          actor,
          Ankole.Kernel.gen_uuid_v7(),
          System.monotonic_time(:millisecond) + 30_000
        )

      token =
        Enum.find_value(headers, fn {key, value} ->
          if key == "x-ankole-caller-mcp-token", do: value
        end)

      {:ok, claims} = Tokens.verify(token)
      {:ok, context} = Access.authorize(claims)
      assert consent_params(context)["intent"] == PodURL.page_path(page.id) <> suffix
    end
  end

  defp native_context(ctx) do
    {:ok, detail} =
      Ankole.ConversationsFixtures.create(ctx.human.uid, %{
        conversation_id: Ankole.Kernel.gen_uuid_v7(),
        message_id: Ankole.Kernel.gen_uuid_v7(),
        agent_uid: ctx.agent.uid,
        text: "Read my repository"
      })

    [signal] =
      Ankole.Signals.list_signals!(query: [filter: [conversation_id: detail.conversation.id]])

    {detail.conversation, worker_context(signal, ctx.agent.uid)}
  end

  defp worker_context(signal, uid) do
    ref = %Ankole.Sessions.RunRef{
      agent_uid: uid,
      session_id: signal.session_id,
      signal_id: signal.id
    }

    {:ok, env} = Tokens.worker(uid, ref)
    {:ok, claims} = Tokens.verify(env["ANKOLE_MCP_TOKEN"])
    {:ok, context} = Access.authorize(claims)
    context
  end

  defp consent_params(
         context,
         toolkit \\ "github",
         name \\ "repos_get",
         args \\ %{"owner" => "example", "repo" => "project"}
       ) do
    assert {:error, %{code: "oauth_consent_required", authorization_url: url}} =
             Gateway.request(
               {:toolkit, toolkit},
               %{"method" => "tools/call", "params" => %{"name" => name, "arguments" => args}},
               context,
               %{}
             )

    url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
  end
end
