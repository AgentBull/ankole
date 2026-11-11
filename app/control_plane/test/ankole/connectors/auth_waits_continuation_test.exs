defmodule Ankole.Connectors.AuthWaitsContinuationTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures

  alias Ankole.Connectors.{Access, Accounts, AuthWait, AuthWaits, Gateway, OAuth, Store, Tokens}
  alias Ankole.Conversations
  alias Ankole.Pod.Chat.Presentation
  alias Ankole.Sessions.Presentation.Execution

  defmodule Provider do
    import Plug.Conn
    def init(owner), do: owner

    def call(conn, _owner) do
      case {conn.method, conn.request_path} do
        {"POST", "/login/oauth/access_token"} ->
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
        "display_name" => "GitHub (Work)",
        "secret" => %{"client_id" => "return-test", "client_secret" => "secret"},
        "public_metadata" => %{
          "base_url" => "http://127.0.0.1:#{port}",
          "web_url" => "http://127.0.0.1:#{port}"
        }
      })

    %{
      human: human,
      actor: actor_fixture(human),
      admin: admin,
      agent: agent,
      config: config,
      port: port
    }
  end

  test "OAuth claim resolves a blocked conversation turn in ascending lock order and enqueues continuation",
       ctx do
    {conversation, signal, context} = start_conversation_turn(ctx)

    assert {:error, %{code: "oauth_consent_required", authorization_url: auth_url}} =
             Gateway.request(
               {:toolkit, "github"},
               %{
                 "method" => "tools/call",
                 "params" => %{
                   "name" => "repos_get",
                   "arguments" => %{"owner" => "acme", "repo" => "app"}
                 }
               },
               context,
               %{}
             )

    assert [%AuthWait{status: "recorded", toolkit: "github"} = recorded] =
             AuthWaits.list_for_signal(signal.id)

    at = DateTime.utc_now(:second)

    execution =
      Execution.from_chain(
        [
          %{
            id: "round-1",
            content: [
              %{
                "type" => "function_call",
                "call_id" => "call_gh",
                "name" => "command",
                "arguments" =>
                  Torque.encode!(%{
                    "command" => "mcporter call github.repos_get owner=acme repo=app"
                  })
              },
              %{
                "type" => "function_call_output",
                "call_id" => "call_gh",
                "output" => "exit_code=1\nduration=25ms\noauth_consent_required"
              }
            ],
            metadata: %{},
            inserted_at: at,
            updated_at: at
          }
        ],
        %{},
        "completed",
        blocked_toolkits: ["github"]
      )

    assert [%{"status" => "blocked"}] = execution["steps"]

    post_turn_reply!(
      ctx,
      conversation,
      signal,
      "I need GitHub access to inspect acme/app.",
      execution
    )

    {:ok, detail} = Conversations.get(ctx.actor, conversation.id)
    projected = Presentation.detail(detail)
    assert projected.conversation.rowStatus == "waiting_choice"

    reply_msg = List.last(projected.messages)
    assert reply_msg.richContent["connector_auth"]["state"] == "pending"
    assert reply_msg.richContent["connector_auth"]["display_name"] == "GitHub (Work)"
    assert reply_msg.richContent["connector_auth"]["connection_slug"] == "work"

    params = auth_url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    return_to = "/connectors?" <> URI.encode_query(params)

    assert {:ok, %{authorization_url: provider_url}} =
             OAuth.begin(ctx.human, %{
               "connection" => "work",
               "scopes" => ["repo"],
               "return_to" => return_to
             })

    oauth_state = provider_url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert {:ok, %{completion_code: code}} =
             OAuth.callback(%{"state" => oauth_state["state"], "code" => "ok-code"})

    assert {:ok, %{external_subject_id: "42"}} = OAuth.claim(ctx.human, code)

    assert [%AuthWait{id: wait_id, status: "completed"}] = AuthWaits.list_for_signal(signal.id)
    assert wait_id == recorded.id

    wakes =
      Ankole.Signals.list_signals!(
        query: [filter: [conversation_id: conversation.id, type: "signal.action.invoked"]]
      )

    assert [wake] = wakes

    assert wake.data["action"]["value"]["answer"] == %{
             "kind" => "connector_connected",
             "value" => "work"
           }

    assert wake.data["action"]["value"]["source_signal_id"] == signal.id

    {:ok, refreshed_detail} = Conversations.get(ctx.actor, conversation.id)

    refreshed_msg =
      refreshed_detail |> Presentation.detail() |> Map.fetch!(:messages) |> List.last()

    assert refreshed_msg.richContent["connector_auth"]["state"] == "answered"
  end

  test "personal token binding wakes an unmaterialized connector wait once materialized", ctx do
    {conversation, signal, context} = start_conversation_turn(ctx)

    assert :ok =
             AuthWaits.record_blocked_turn(
               %{
                 connection: "figma",
                 scopes: ["file_content:read"],
                 authorization_url: "/connectors?connection=figma&subject_kind=human"
               },
               context,
               "figma",
               "get_file"
             )

    assert [%AuthWait{auth_config_id: nil, connection_slug: "figma", status: "recorded"}] =
             AuthWaits.list_for_signal(signal.id)

    post_turn_reply!(ctx, conversation, signal, "Please connect Figma.", nil)

    {:ok, figma_config} =
      Store.create_auth_config(ctx.admin, %{
        "plugin_id" => "figma",
        "slug" => "figma",
        "auth_scheme" => "personal_token",
        "display_name" => "Figma",
        "secret" => %{}
      })

    assert {:ok, _account} =
             Accounts.put_human_tokens(
               figma_config.id,
               ctx.human.uid,
               %{"access_token" => "figd_secret"},
               %{granted_scopes: ["file_content:read"], external_subject_id: "u_1"}
             )

    assert [%AuthWait{status: "completed", auth_config_id: resolved_config_id}] =
             AuthWaits.list_for_signal(signal.id)

    assert resolved_config_id == figma_config.id

    assert [wake] =
             Ankole.Signals.list_signals!(
               query: [filter: [conversation_id: conversation.id, type: "signal.action.invoked"]]
             )

    assert wake.data["action"]["value"]["answer"] == %{
             "kind" => "connector_connected",
             "value" => "figma"
           }
  end

  test "early account connection before final reply posting completes wait and returns wake signal immediately",
       ctx do
    {conversation, signal, context} = start_conversation_turn(ctx)

    assert {:error, %{code: "oauth_consent_required"}} =
             Gateway.request(
               {:toolkit, "github"},
               %{
                 "method" => "tools/call",
                 "params" => %{
                   "name" => "repos_get",
                   "arguments" => %{"owner" => "acme", "repo" => "app"}
                 }
               },
               context,
               %{}
             )

    assert [%AuthWait{status: "recorded"}] = AuthWaits.list_for_signal(signal.id)

    # Human completes OAuth while the turn is still composing its final reply (record -> connect -> post).
    assert {:ok, _account} =
             Accounts.put_human_tokens(
               ctx.config.id,
               ctx.human.uid,
               %{"access_token" => "gho_early_token"},
               %{granted_scopes: ["repo"], external_subject_id: "early_u1"}
             )

    {:ok, posted} =
      post_turn_reply!(ctx, conversation, signal, "Please connect GitHub.", nil)

    assert [wake] = posted.signals
    assert wake.type == "signal.action.invoked"

    assert wake.data["action"]["value"]["answer"] == %{
             "kind" => "connector_connected",
             "value" => "work"
           }

    assert [%AuthWait{status: "completed"}] = AuthWaits.list_for_signal(signal.id)

    {:ok, detail} = Conversations.get(ctx.actor, conversation.id)
    last_msg = detail |> Presentation.detail() |> Map.fetch!(:messages) |> List.last()
    assert last_msg.richContent["connector_auth"]["state"] == "answered"
    assert last_msg.richContent["connector_auth"]["human_uid"] == ctx.human.uid
  end

  test "a newer user message supersedes a pending connector auth wait without duplicate wake",
       ctx do
    {conversation, signal, context} = start_conversation_turn(ctx)

    assert {:error, %{code: "oauth_consent_required"}} =
             Gateway.request(
               {:toolkit, "github"},
               %{
                 "method" => "tools/call",
                 "params" => %{
                   "name" => "repos_get",
                   "arguments" => %{"owner" => "acme", "repo" => "app"}
                 }
               },
               context,
               %{}
             )

    post_turn_reply!(ctx, conversation, signal, "Please connect GitHub.", nil)

    assert {:ok, _} =
             Conversations.post(ctx.actor, conversation.id, %{
               message_id: Ankole.Kernel.gen_uuid_v7(),
               text: "Never mind, skip GitHub for now.",
               agent_uid: ctx.agent.uid
             })

    assert {:ok, _account} =
             Accounts.put_human_tokens(
               ctx.config.id,
               ctx.human.uid,
               %{"access_token" => "late-token"},
               %{granted_scopes: ["repo"], external_subject_id: "42"}
             )

    assert [%AuthWait{status: "superseded"}] = AuthWaits.list_for_signal(signal.id)

    assert [] ==
             Ankole.Signals.list_signals!(
               query: [filter: [conversation_id: conversation.id, type: "signal.action.invoked"]]
             )

    {:ok, detail} = Conversations.get(ctx.actor, conversation.id)
    projected = Presentation.detail(detail)
    blocked_msg = Enum.find(projected.messages, &(&1.richContent["connector_auth"] != nil))
    assert blocked_msg.richContent["connector_auth"]["state"] == "superseded"
  end

  test "background agent job turns do not record connector auth waits", ctx do
    job_ref = %Ankole.Sessions.RunRef{
      agent_uid: ctx.agent.uid,
      session_id: "job:" <> Ankole.Kernel.gen_uuid_v7(),
      signal_id: Ankole.Kernel.gen_uuid_v7()
    }

    context = %{
      actor: Ankole.AuthZ.Actor.new(ctx.agent, turn_authority: {job_ref, ctx.human.uid}),
      read_only: false,
      deadline: System.monotonic_time(:millisecond) + 30_000
    }

    assert {:error, %{code: "oauth_consent_required"}} =
             Gateway.request(
               {:toolkit, "github"},
               %{
                 "method" => "tools/call",
                 "params" => %{
                   "name" => "repos_get",
                   "arguments" => %{"owner" => "acme", "repo" => "app"}
                 }
               },
               context,
               %{}
             )

    assert [] == AuthWaits.list_for_signal(job_ref.signal_id)
  end

  defp start_conversation_turn(ctx) do
    {:ok, detail} =
      Ankole.ConversationsFixtures.create(ctx.human.uid, %{
        conversation_id: Ankole.Kernel.gen_uuid_v7(),
        message_id: Ankole.Kernel.gen_uuid_v7(),
        agent_uid: ctx.agent.uid,
        text: "Read my repository"
      })

    [signal] =
      Ankole.Signals.list_signals!(query: [filter: [conversation_id: detail.conversation.id]])

    ref = %Ankole.Sessions.RunRef{
      agent_uid: ctx.agent.uid,
      session_id: signal.session_id,
      signal_id: signal.id
    }

    {:ok, env} = Tokens.worker(ctx.agent.uid, ref)
    {:ok, claims} = Tokens.verify(env["ANKOLE_MCP_TOKEN"])
    {:ok, context} = Access.authorize(claims)

    {detail.conversation, signal, context}
  end

  defp post_turn_reply!(ctx, conversation, signal, text, execution) do
    {:ok, _} =
      Repo.transact_top_level(fn ->
        :ok = Ankole.Sessions.Queue.lock_sessions_in_tx([{ctx.agent.uid, signal.session_id}])

        target = %Ankole.Conversations.Target{
          kind: :native,
          conversation_id: conversation.id
        }

        statement = %Ankole.Conversations.Statement{
          signal: signal,
          completion: %{
            answer_text: text,
            execution: execution,
            attachments: []
          },
          now: DateTime.utc_now(:microsecond)
        }

        Ankole.Conversations.post_in_tx(target, statement)
      end)
  end
end
