defmodule Ankole.Connectors.ApprovalsTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  require Ash.Query

  alias Ankole.Connectors.{Access, Accounts, Gateway, Store, Tokens}
  alias Ankole.Conversations
  alias Ankole.Conversations.ActionCards
  alias Ankole.Plugins.LarkAdapter.Config, as: LarkConfig
  alias Ankole.Pod.Chat.Presentation
  alias Ankole.Sessions.Presentation.Execution

  defmodule Provider do
    import Plug.Conn
    def init(owner), do: owner

    def call(conn, owner) do
      {:ok, body, conn} = read_body(conn)
      decoded = if body == "", do: nil, else: Torque.decode!(body)
      send(owner, {:upstream, conn.method, conn.request_path, decoded})

      case {conn.method, conn.request_path} do
        {"POST", "/open-apis/auth/v3/tenant_access_token/internal"} ->
          json_resp(conn, 200, %{
            "code" => 0,
            "tenant_access_token" => "lark-app-token",
            "expire" => 7200
          })

        {"PATCH", "/open-apis/calendar/v4/calendars/cal-1/events/ev-1"} ->
          json_resp(conn, 200, %{
            "code" => 0,
            "data" => %{"event" => %{"event_id" => "ev-1", "summary" => decoded["summary"]}}
          })

        {"DELETE", "/open-apis/calendar/v4/calendars/cal-1/events/ev-fail-before-send"} ->
          json_resp(conn, 422, %{"code" => 99_991_663, "msg" => "invalid event"})

        {"DELETE", "/open-apis/calendar/v4/calendars/cal-1/events/ev-1"} ->
          json_resp(conn, 200, %{"code" => 0, "data" => %{}})

        {"POST", "/open-apis/calendar/v4/calendars/cal-1/events/ev-1/reply"} ->
          json_resp(conn, 200, %{"code" => 0, "data" => %{}})

        {"POST", "/skill-mcp"} ->
          envelope = %{"jsonrpc" => "2.0", "id" => decoded["id"]}

          case decoded["method"] do
            "tools/list" ->
              json_resp(
                conn,
                200,
                Map.put(envelope, "result", %{
                  "tools" => [
                    %{
                      "name" => "delete_remote",
                      "inputSchema" => %{"type" => "object"},
                      "annotations" => %{"destructiveHint" => true}
                    }
                  ]
                })
              )

            "tools/call" ->
              json_resp(
                conn,
                200,
                Map.put(envelope, "result", %{
                  "isError" => true,
                  "content" => [%{"type" => "text", "text" => "Could not confirm remote write"}]
                })
              )
          end
      end
    end

    defp json_resp(conn, status, payload) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Torque.encode!(payload))
    end
  end

  setup do
    human = human_fixture().principal
    admin = human_fixture().principal
    {:ok, _} = Repo.transact(fn -> Ankole.AuthZ.add_pod_admin_in_tx(admin.uid) end)
    agent = agent_fixture(%{type: :personal_assistant, owner_principal_uid: human.uid}).principal

    server = start_supervised!({Bandit, plug: {Provider, self()}, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    url = "http://127.0.0.1:#{port}"

    previous = Application.get_env(:ankole, LarkConfig)
    Application.put_env(:ankole, LarkConfig, client_opts: [base_url: url])
    on_exit(fn -> Application.put_env(:ankole, LarkConfig, previous || []) end)

    {:ok, config} =
      Store.create_auth_config(admin, %{
        "plugin_id" => "lark",
        "slug" => "lark-work",
        "auth_scheme" => "lark_app",
        "display_name" => "Feishu (Work)",
        "is_default" => true,
        "secret" => %{"appID" => "cli_test", "appSecret" => "secret"},
        "public_metadata" => %{"domain" => "feishu"}
      })

    {:ok, account} =
      Accounts.put_human_tokens(
        config.id,
        human.uid,
        %{"access_token" => "human-lark-token", "expires_in" => 3600},
        %{
          external_subject_id: "ou_test",
          granted_scopes: [
            "calendar:calendar.event:update",
            "calendar:calendar.event:delete",
            "calendar:calendar.event:reply"
          ]
        }
      )

    %{
      human: human,
      actor: actor_fixture(human),
      admin: admin,
      agent: agent,
      config: config,
      account: account,
      mcp_url: url <> "/skill-mcp"
    }
  end

  test "default annotations policy allows normal writes, intercepts destructive calls once, and executes locked args once on confirm",
       ctx do
    {conversation, signal, context} = start_conversation_turn(ctx)

    # 1. Non-destructive write passes right through without popup
    assert {:ok, _} =
             call_tool(context, "calendar_patch_event", %{
               "calendar_id" => "cal-1",
               "event_id" => "ev-1",
               "summary" => "Team sync"
             })

    assert_receive {:upstream, "PATCH", "/open-apis/calendar/v4/calendars/cal-1/events/ev-1",
                    %{"summary" => "Team sync"}}

    # 2. Destructive write pauses with approval_required and zero upstream request
    delete_args = %{"calendar_id" => "cal-1", "event_id" => "ev-1"}

    assert {:error,
            %{
              code: "approval_required",
              card_id: card_id,
              retryable: false,
              request_sent: false,
              message: message
            }} = call_tool(context, "calendar_delete_event", delete_args)

    assert message =~ "do not call it again"
    refute_receive {:upstream, "DELETE", _, _}

    # Repeating the exact call in the same turn reuses the same prepared card
    assert {:error, %{code: "approval_required", card_id: ^card_id}} =
             call_tool(context, "calendar_delete_event", delete_args)

    # 3. Turn completion attaches the prepared ActionCard to the conversation message
    post_turn_reply!(ctx, conversation, signal, "Please confirm deleting event ev-1.")

    {:ok, detail} = Conversations.get(ctx.actor, conversation.id)
    projected = Presentation.detail(detail)
    reply_msg = List.last(projected.messages)
    assert reply_msg.richContent["action_card"]["card_id"] == card_id
    assert reply_msg.richContent["action_card"]["action_kind"] == "connectors.tool.call"
    assert reply_msg.richContent["action_card"]["status"] == "prepared"
    assert reply_msg.richContent["action_card"]["payload"]["destructive"] == true

    # 4. Human confirmation executes the locked arguments exactly once and wakes the Agent
    assert {:ok, updated_detail} =
             ActionCards.resolve_native(ctx.actor, conversation.id, card_id, :confirm)

    assert_receive {:upstream, "DELETE", "/open-apis/calendar/v4/calendars/cal-1/events/ev-1", _}

    updated_projected = Presentation.detail(updated_detail)
    updated_reply = Enum.find(updated_projected.messages, &(&1.id == reply_msg.id))
    assert updated_reply.richContent["action_card"]["status"] == "executed"

    assert updated_reply.richContent["action_card"]["resolution_note"] =~
             "Executed Feishu (Work) · calendar_delete_event once"

    wakes =
      Ankole.Signals.list_signals!(
        query: [
          filter: [conversation_id: conversation.id, type: "conversation.action_card.executed"]
        ]
      )

    assert [wake] = wakes
    assert wake.data["text"] =~ "Do not call this tool again"

    # 5. Second confirm click is an idempotent no-op with zero duplicate upstream requests
    assert {:ok, _} = ActionCards.resolve_native(ctx.actor, conversation.id, card_id, :confirm)
    refute_receive {:upstream, "DELETE", _, _}
  end

  test "approval policy transitions (approval_tools, all, none) preserve OAuth accounts and enforce configured gates",
       ctx do
    {_conversation, _signal, context} = start_conversation_turn(ctx)

    # Reject invalid policy value
    assert {:error, :invalid_connection} =
             Store.update_auth_config(ctx.admin, ctx.config.id, %{
               "public_metadata" => %{"domain" => "feishu", "approval" => "bogus"}
             })

    # Add calendar_patch_event to approval_tools without invalidating existing human OAuth account
    {:ok, _} =
      Store.update_auth_config(ctx.admin, ctx.config.id, %{
        "public_metadata" => %{
          "domain" => "feishu",
          "approval" => "annotations",
          "approval_tools" => ["calendar_patch_event"]
        }
      })

    assert {:ok, reloaded_account} = Ankole.Connectors.get_account_by_id(ctx.account.id)
    assert reloaded_account.status == "active"

    assert {:error, %{code: "approval_required", request_sent: false}} =
             call_tool(context, "calendar_patch_event", %{
               "calendar_id" => "cal-1",
               "event_id" => "ev-1",
               "summary" => "Needs approval via approval_tools"
             })

    refute_receive {:upstream, "PATCH", _, _}

    # Policy "all" intercepts any non-readOnlyHint write even without approval_tools
    {:ok, _} =
      Store.update_auth_config(ctx.admin, ctx.config.id, %{
        "public_metadata" => %{"domain" => "feishu", "approval" => "all"}
      })

    {_conversation2, _signal2, context2} = start_conversation_turn(ctx)

    assert {:error, %{code: "approval_required", request_sent: false}} =
             call_tool(context2, "calendar_patch_event", %{
               "calendar_id" => "cal-1",
               "event_id" => "ev-1",
               "summary" => "Needs approval via all"
             })

    # Policy "none" allows destructive calls immediately without approval
    {:ok, _} =
      Store.update_auth_config(ctx.admin, ctx.config.id, %{
        "public_metadata" => %{"domain" => "feishu", "approval" => "none"}
      })

    assert {:ok, _} =
             call_tool(context, "calendar_delete_event", %{
               "calendar_id" => "cal-1",
               "event_id" => "ev-1"
             })

    assert_receive {:upstream, "DELETE", "/open-apis/calendar/v4/calendars/cal-1/events/ev-1", _}
  end

  test "enforces 16 KB payload limit and rejects unattended non-conversation destructive calls",
       ctx do
    {_conversation, _signal, context} = start_conversation_turn(ctx)

    # > 16 KB arguments rejected before card creation
    oversized = String.duplicate("x", 17_000)

    assert {:error,
            %{
              code: "approval_arguments_too_large",
              retryable: false,
              request_sent: false
            }} =
             call_tool(context, "calendar_delete_event", %{
               "calendar_id" => "cal-1",
               "event_id" => oversized
             })

    # Non-conversation background job turn returns approval_unavailable
    job_ref = %Ankole.Sessions.RunRef{
      agent_uid: ctx.agent.uid,
      session_id: "job:" <> Ankole.Kernel.gen_uuid_v7(),
      signal_id: Ankole.Kernel.gen_uuid_v7()
    }

    unattended_context = %{
      actor: Ankole.AuthZ.Actor.new(ctx.agent, turn_authority: {job_ref, ctx.human.uid}),
      read_only: false,
      deadline: System.monotonic_time(:millisecond) + 30_000
    }

    assert {:error,
            %{
              code: "approval_unavailable",
              retryable: false,
              request_sent: false
            }} =
             call_tool(unattended_context, "calendar_delete_event", %{
               "calendar_id" => "cal-1",
               "event_id" => "ev-1"
             })

    refute_receive {:upstream, "DELETE", _, _}
  end

  test "binds connection and account into WriteReceipts, approval digests, and execute_approved_card verification",
       ctx do
    {:ok, secondary_config} =
      Store.create_auth_config(ctx.admin, %{
        "plugin_id" => "lark",
        "slug" => "lark-secondary",
        "auth_scheme" => "lark_app",
        "display_name" => "Feishu (Secondary)",
        "is_default" => false,
        "secret" => %{"appID" => "cli_secondary", "appSecret" => "secret2"},
        "public_metadata" => %{"domain" => "feishu"}
      })

    {:ok, secondary_account} =
      Accounts.put_human_tokens(
        secondary_config.id,
        ctx.human.uid,
        %{"access_token" => "secondary-lark-token", "expires_in" => 3600},
        %{
          external_subject_id: "ou_secondary",
          granted_scopes: [
            "calendar:calendar.event:delete",
            "calendar:calendar.event:reply"
          ]
        }
      )

    {_conversation, _signal, context} = start_conversation_turn(ctx)

    reply_args = %{
      "calendar_id" => "cal-1",
      "event_id" => "ev-1",
      "rsvp_status" => "accept"
    }

    # Same-turn identical non-idempotent writes across two different accounts both succeed
    assert {:ok, _} = call_tool(context, "calendar_reply_event", reply_args, "lark-work")

    assert_receive {:upstream, "POST", "/open-apis/calendar/v4/calendars/cal-1/events/ev-1/reply",
                    _}

    assert {:ok, _} = call_tool(context, "calendar_reply_event", reply_args, "lark-secondary")

    assert_receive {:upstream, "POST", "/open-apis/calendar/v4/calendars/cal-1/events/ev-1/reply",
                    _}

    # Repeating on the same account in the same turn is still blocked by WriteReceipts
    assert {:error, %{code: "duplicate_turn_write_prevented", request_sent: false}} =
             call_tool(context, "calendar_reply_event", reply_args, "lark-work")

    # Destructive calls with identical args on two accounts create distinct ActionCards & digests across turns
    delete_args = %{"calendar_id" => "cal-1", "event_id" => "ev-1"}

    assert {:error, %{code: "approval_required", card_id: card_a_id}} =
             call_tool(context, "calendar_delete_event", delete_args, "lark-work")

    {conversation_b, _signal_b, context_b} = start_conversation_turn(ctx)

    assert {:error, %{code: "approval_required", card_id: card_b_id}} =
             call_tool(context_b, "calendar_delete_event", delete_args, "lark-secondary")

    refute card_a_id == card_b_id

    card_a = Repo.get_by!(Conversations.ActionCard, id: card_a_id)
    card_b = Repo.get_by!(Conversations.ActionCard, id: card_b_id)
    refute card_a.preconditions["args_sha256"] == card_b.preconditions["args_sha256"]
    assert card_a.summary =~ ctx.human.uid
    assert card_b.summary =~ ctx.human.uid

    # Tampering with locked account_id fails digest verification
    tampered = Map.put(card_a.payload, "account_id", secondary_account.id)
    assert {:error, :tampered} = Ankole.Connectors.Approvals.verify_locked_payload(tampered)

    # Replacing or deleting the locked account makes execute_approved_card return {:stale, _}
    {:ok, _} = Ankole.Ash.destroy(secondary_account, :destroy)

    assert {:stale, stale_msg} = Gateway.execute_approved_card(card_b, ctx.actor)
    assert stale_msg =~ "connection or account changed"
    refute_receive {:upstream, "DELETE", _, _}

    assert {:ok, _} =
             ActionCards.resolve_native(ctx.actor, conversation_b.id, card_b_id, :confirm)

    assert Repo.get_by!(Conversations.ActionCard, id: card_b_id).status == :stale
    refute_receive {:upstream, "DELETE", _, _}
  end

  test "blocks a second distinct approval-gated call in the same turn and cancels unattached prepared cards on clarify or aborted turns",
       ctx do
    {conversation, signal, context} = start_conversation_turn(ctx)

    assert {:error,
            %{
              code: "approval_required",
              card_id: first_card_id,
              retryable: false,
              request_sent: false
            }} =
             call_tool(context, "calendar_delete_event", %{
               "calendar_id" => "cal-1",
               "event_id" => "ev-1"
             })

    assert {:error,
            %{
              code: "approval_already_pending",
              card_id: ^first_card_id,
              retryable: false,
              request_sent: false,
              message: pending_msg
            }} =
             call_tool(context, "calendar_delete_event", %{
               "calendar_id" => "cal-1",
               "event_id" => "ev-2"
             })

    assert pending_msg =~ "already pending for this turn"

    cards =
      Conversations.ActionCard
      |> Ash.Query.filter(source_signal_id == ^signal.id)
      |> Ankole.Ash.read!()

    assert [%{id: ^first_card_id, status: :prepared}] = cards

    assert MapSet.member?(
             ActionCards.prepared_conversation_ids([conversation.id]),
             conversation.id
           )

    # Clarify prompt takes precedence at turn settlement and cancels the unattached prepared connector card
    clarify_prompt = %{
      "body" => "Which event should I delete?",
      "choices" => [%{"id" => "ev1", "label" => "ev-1"}],
      "free_input" => true,
      "interaction_id" => "clarify:call_1",
      "interactive_output" => %{
        "interaction_id" => "clarify:call_1",
        "body" => "Which event should I delete?",
        "choices" => [%{"id" => "ev1", "label" => "ev-1"}],
        "free_input" => true
      }
    }

    execution = Execution.from_chain([], %{}, "completed")

    {:ok, _} =
      Repo.transact_top_level(fn ->
        :ok = Ankole.Sessions.Queue.lock_sessions_in_tx([{ctx.agent.uid, signal.session_id}])

        Ankole.Conversations.post_in_tx(
          %Ankole.Conversations.Target{kind: :native, conversation_id: conversation.id},
          %Ankole.Conversations.Statement{
            signal: signal,
            completion: %{
              answer_text: "Which event should I delete?",
              clarify_prompt: clarify_prompt,
              execution: execution,
              attachments: []
            },
            now: DateTime.utc_now(:microsecond)
          }
        )
      end)

    assert Repo.get_by!(Conversations.ActionCard, id: first_card_id).status == :cancelled
    assert ActionCards.prepared_conversation_ids([conversation.id]) == MapSet.new()

    # Aborted (:stopped) turn via Sessions.Run.reject_input_in_tx also cancels mid-turn prepared cards
    {aborted_conv, aborted_signal, aborted_ctx} = start_conversation_turn(ctx)

    assert {:error, %{code: "approval_required", card_id: aborted_card_id}} =
             call_tool(aborted_ctx, "calendar_delete_event", %{
               "calendar_id" => "cal-1",
               "event_id" => "ev-99"
             })

    assert MapSet.member?(
             ActionCards.prepared_conversation_ids([aborted_conv.id]),
             aborted_conv.id
           )

    {:ok, _} =
      Repo.transact_top_level(fn ->
        Ankole.Sessions.Run.reject_input_in_tx(aborted_signal, :stopped, nil)
      end)

    assert Repo.get_by!(Conversations.ActionCard, id: aborted_card_id).status == :cancelled
    assert ActionCards.prepared_conversation_ids([aborted_conv.id]) == MapSet.new()
  end

  test "approval follows the locked connection ID when an administrator renames its slug", ctx do
    {conversation, _signal, context} = start_conversation_turn(ctx)

    assert {:error, %{code: "approval_required", card_id: card_id}} =
             call_tool(context, "calendar_delete_event", %{
               "calendar_id" => "cal-1",
               "event_id" => "ev-1"
             })

    assert {:ok, _} =
             Store.update_auth_config(ctx.admin, ctx.config.id, %{"slug" => "lark-renamed"})

    assert {:ok, _} = ActionCards.resolve_native(ctx.actor, conversation.id, card_id, :confirm)
    assert_receive {:upstream, "DELETE", "/open-apis/calendar/v4/calendars/cal-1/events/ev-1", _}
    assert Repo.get_by!(Conversations.ActionCard, id: card_id).status == :executed
  end

  test "408/499 keep WriteReceipts settled, failed pre-send card wakeup does not claim execution, and human-OAuth cards redact for non-owners",
       ctx do
    # 1. 408/499 are uncertain outcomes, not pre-send 4xx releases
    assert {:error, %{status: 408}} =
             Ankole.Connectors.WriteReceipts.execute_scope(
               "signal:req-408",
               "toolkit:cfg:acc",
               "create_item",
               %{"a" => 1},
               fn -> {:error, %{status: 408, message: "Request timeout"}} end
             )

    assert {:error, %{code: "previous_write_outcome_unknown"}} =
             Ankole.Connectors.WriteReceipts.execute_scope(
               "signal:req-408",
               "toolkit:cfg:acc",
               "create_item",
               %{"a" => 1},
               fn -> flunk("must not replay after 408") end
             )

    assert {:error, %{status: 499}} =
             Ankole.Connectors.WriteReceipts.execute_scope(
               "signal:req-499",
               "toolkit:cfg:acc",
               "create_item",
               %{"a" => 1},
               fn -> {:error, %{status: 499, message: "Client closed request"}} end
             )

    assert {:error, %{code: "previous_write_outcome_unknown"}} =
             Ankole.Connectors.WriteReceipts.execute_scope(
               "signal:req-499",
               "toolkit:cfg:acc",
               "create_item",
               %{"a" => 1},
               fn -> flunk("must not replay after 499") end
             )

    # 2. Failed-before-send approved card wakeup must not claim "already been executed once"
    {conversation, _signal, context} = start_conversation_turn(ctx)

    assert {:error, %{code: "approval_required", card_id: card_id}} =
             call_tool(context, "calendar_delete_event", %{
               "calendar_id" => "cal-1",
               "event_id" => "ev-fail-before-send"
             })

    card = Repo.get_by!(Conversations.ActionCard, id: card_id)
    assert card.payload["subject_kind"] == "human"

    # Other active human / guest in workspace cannot see or view human-OAuth card target or arguments_preview
    other_human = human_fixture().principal
    other_actor = Ankole.AuthZ.Actor.new(other_human)
    refute Conversations.ActionCards.DomainActions.can_view_card_target?(other_actor, card)

    redacted_state = ActionCards.client_card_state(card, other_actor)
    assert redacted_state["payload"]["redacted"] == true
    refute Map.has_key?(redacted_state["payload"], "arguments_preview")
    assert redacted_state["resolution_note"] == nil

    # Real resolve_native hits Provider's HTTP 422 response -> :failed_not_sent -> "[Action Card Failed]"
    assert {:ok, _} = ActionCards.resolve_native(ctx.actor, conversation.id, card_id, :confirm)

    assert_receive {:upstream, "DELETE",
                    "/open-apis/calendar/v4/calendars/cal-1/events/ev-fail-before-send", _}

    [wakeup] =
      Ankole.Signals.list_signals!(
        query: [filter: [conversation_id: conversation.id], sort: [inserted_at: :desc], limit: 1]
      )

    assert wakeup.data["text"] =~ "[Action Card Failed]"
    assert wakeup.data["text"] =~ "failed before mutating upstream state"
    refute wakeup.data["text"] =~ "already been executed once"
    refute wakeup.data["text"] =~ "upstream outcome uncertain"
  end

  test "approved Skill MCP calls returning isError settle as :execution_uncertain instead of :executed",
       ctx do
    yaml = """
    dependencies:
      tools:
        - type: mcp
          value: skill-server
          transport: streamable_http
          url: #{ctx.mcp_url}
    """

    {:ok, blob} = Ankole.Files.store(yaml)

    {:ok, _} =
      Ankole.Files.commit(ctx.agent.uid, [
        Map.merge(blob, %{path: "mcp/mcp-approval-err", source: "agent"})
      ])

    {:ok, _} =
      Repo.transact_top_level(fn ->
        with {:ok, skill} <-
               Ankole.Ash.create(Ankole.AIAgent.Library.Schemas.Skill, :create, %{
                 slug: "mcp-approval-err",
                 name: "mcp-approval-err",
                 description: "fixture",
                 source_kind: :custom,
                 enabled_for_all: true,
                 manifest_xml: "<p>fixture</p>",
                 manifest_markdown: "fixture"
               }),
             do:
               Ankole.Ash.create(Ankole.AIAgent.Library.Schemas.SkillFile, :put, %{
                 skill_id: skill.id,
                 relative_path: "agents/openai.yaml",
                 object_id: blob.object_id,
                 content_type: "application/yaml"
               })
      end)

    {conversation, _signal, context} = start_conversation_turn(ctx)

    assert {:error, %{code: "approval_required", card_id: card_id}} =
             Gateway.request(
               {:skill, "mcp-approval-err", "skill-server"},
               %{
                 "method" => "tools/call",
                 "params" => %{"name" => "delete_remote", "arguments" => %{}}
               },
               context,
               %{}
             )

    assert {:ok, _} = ActionCards.resolve_native(ctx.actor, conversation.id, card_id, :confirm)

    assert_receive {:upstream, "POST", "/skill-mcp", %{"method" => "tools/call"}}

    card = Repo.get_by!(Conversations.ActionCard, id: card_id)
    assert card.status == :execution_uncertain
    assert card.resolution_note =~ "Could not confirm remote write"

    receipt =
      Repo.get_by!(Ankole.Connectors.WriteReceipt, authority_scope: "action_card:" <> card_id)

    assert receipt.status == "outcome_unknown"

    [wakeup] =
      Ankole.Signals.list_signals!(
        query: [filter: [conversation_id: conversation.id], sort: [inserted_at: :desc], limit: 1]
      )

    assert wakeup.data["text"] =~ "upstream outcome uncertain"
    assert wakeup.data["text"] =~ "Could not confirm remote write"
    refute wakeup.data["text"] =~ "[Action Card Executed]"
  end

  defp call_tool(context, name, args, connection \\ "lark-work") do
    Gateway.request(
      {:toolkit, "lark_calendar"},
      %{"method" => "tools/call", "params" => %{"name" => name, "arguments" => args}},
      context,
      %{"connection" => connection}
    )
  end

  defp start_conversation_turn(ctx) do
    {:ok, detail} =
      Ankole.ConversationsFixtures.create(ctx.human.uid, %{
        conversation_id: Ankole.Kernel.gen_uuid_v7(),
        message_id: Ankole.Kernel.gen_uuid_v7(),
        agent_uid: ctx.agent.uid,
        text: "Manage my calendar event"
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

  defp post_turn_reply!(ctx, conversation, signal, text) do
    execution = Execution.from_chain([], %{}, "completed")

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
