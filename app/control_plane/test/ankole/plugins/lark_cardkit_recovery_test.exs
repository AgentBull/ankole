defmodule Ankole.Plugins.LarkAdapter.CardKitRecoveryTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures
  import Ankole.SignalsGatewayFixtures

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Cache, as: AppConfigureCache
  alias Ankole.AppConfigure.Registry, as: AppConfigureRegistry
  alias Ankole.Plugins.LarkAdapter
  alias Ankole.Plugins.LarkAdapter.CardKit
  alias Ankole.Plugins.LarkAdapter.CardKit.CardChain
  alias Ankole.Plugins.LarkAdapter.Config
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.Actors
  alias Ankole.SignalsGateway.OutboxEntry
  alias Ankole.SignalsGateway.ReplyPresentation
  alias Ankole.SignalsGateway.ReplyPreviewAdapter.Request
  alias FeishuOpenAPI.Error

  setup do
    AppConfigureRegistry.clear_for_test()
    AppConfigureCache.clear_for_test()
    :ok = AppConfigure.register_patterns(LarkAdapter.app_config_patterns())

    config_id = "cardkit-recovery-#{System.unique_integer([:positive])}"

    assert {:ok, _config} =
             AppConfigure.put_global_by_key(Config.chat_config_key(config_id), %{
               "appID" => "cli_cardkit_test",
               "appSecret" => "secret"
             })

    %{principal: agent} = agent_fixture()

    assert {:ok, _binding} =
             SignalsGateway.upsert_binding(%{
               agent_uid: agent.uid,
               name: "lark-cardkit",
               adapter: "lark",
               config_ref: "app-config://#{Config.chat_config_key(config_id)}",
               filters: %{},
               unaddressed_group_message_policy: :ignore
             })

    %{actor_event: event} =
      emit_addressed_actor_event(
        agent.uid,
        "lark-cardkit",
        group_entry(%{
          source_event_id: unique_uid("cardkit-event"),
          source_entry_id: unique_uid("cardkit-trigger"),
          explicit: true
        })
      )

    %{event: event}
  end

  test "restart refresh deletes a leased thought absent from the durable projection and closes streaming",
       %{event: event} do
    presentation =
      ReplyPresentation.new()
      |> ReplyPresentation.append_answer("仍在运行")

    checkpoint = %{
      "schema_version" => 1,
      "adapter" => "lark",
      "card_id" => "card-recovered",
      "message_id" => "message-recovered",
      "message_uuid" => "message-uuid",
      "streaming_state" => "open",
      "stream_deadline_at" => "2026-07-14T02:00:00.000000Z",
      "element_ids" => ["state", "thought", "answer"],
      "presentation" => ReplyPresentation.checkpoint(presentation),
      "refresh_pending" => true,
      "refresh_reason" => "thought_cleanup"
    }

    assert {:ok, stored} = Actors.put_reply_preview_checkpoint(event.id, checkpoint)
    parent = self()

    request_fun = fn _client, method, path, opts ->
      send(parent, {:cardkit_request, method, path, opts})
      {:ok, %{"data" => %{}}}
    end

    assert {:ok, result} =
             CardKit.refresh(
               %Request{
                 actor_event: stored,
                 presentation: presentation,
                 previous_presentation: checkpoint["presentation"],
                 checkpoint: checkpoint,
                 mode: :working
               },
               client: :recording_client,
               request_fun: request_fun
             )

    assert_receive {:cardkit_request, :post, "cardkit/v1/cards/:card_id/batch_update",
                    delete_opts}

    delete_actions = delete_opts[:body][:actions] |> Ankole.JSON.decode!()

    assert Enum.any?(delete_actions, fn action ->
             action["action"] == "delete_elements" and
               "thought" in get_in(action, ["params", "element_ids"])
           end)

    assert_receive {:cardkit_request, :post, "cardkit/v1/cards/:card_id/batch_update", close_opts}

    close_actions = close_opts[:body][:actions] |> Ankole.JSON.decode!()
    assert close_opts[:body][:sequence] == delete_opts[:body][:sequence] + 1

    assert Enum.any?(close_actions, fn action ->
             action["action"] == "partial_update_setting" and
               get_in(action, ["params", "settings", "config", "streaming_mode"]) == false
           end)

    assert result.reply_preview_checkpoint["streaming_state"] == "closed"
    assert result.reply_preview_checkpoint["stream_deadline_at"] == nil
    refute result.reply_preview_checkpoint["refresh_pending"]
    refute result.reply_preview_checkpoint["cleanup_at"]

    persisted = Repo.get!(ActorEvent, event.id)
    assert persisted.reply_preview_checkpoint["streaming_state"] == "closed"
    refute persisted.reply_preview_cleanup_at
  end

  test "an ambiguous CardKit retry reuses the pending mutation UUID and sequence", %{event: event} do
    presentation = ReplyPresentation.new() |> ReplyPresentation.append_answer("恢复中的回答")

    checkpoint = %{
      "schema_version" => 1,
      "adapter" => "lark",
      "card_id" => "card-retry",
      "message_id" => "message-retry",
      "message_uuid" => "message-retry-uuid",
      "streaming_state" => "open",
      "element_ids" => ["state", "thought", "answer"],
      "presentation" => ReplyPresentation.checkpoint(presentation),
      "refresh_pending" => true,
      "refresh_reason" => "thought_cleanup"
    }

    assert {:ok, stored} = Actors.put_reply_preview_checkpoint(event.id, checkpoint)
    attempts = :counters.new(1, [])
    parent = self()

    request_fun = fn _client, :post, "cardkit/v1/cards/:card_id/batch_update", opts ->
      :counters.add(attempts, 1, 1)
      send(parent, {:mutation_attempt, opts[:body][:sequence], opts[:body][:uuid]})

      if :counters.get(attempts, 1) == 1,
        do: {:error, :timeout},
        else: {:ok, %{"data" => %{}}}
    end

    request = %Request{
      actor_event: stored,
      presentation: presentation,
      previous_presentation: checkpoint["presentation"],
      checkpoint: checkpoint,
      mode: :working
    }

    assert {:error, :timeout} =
             CardKit.refresh(request,
               client: :recording_client,
               request_fun: request_fun
             )

    assert {:ok, _result} =
             CardKit.refresh(request,
               client: :recording_client,
               request_fun: request_fun
             )

    assert_receive {:mutation_attempt, first_sequence, first_uuid}
    assert_receive {:mutation_attempt, second_sequence, second_uuid}
    assert first_sequence == second_sequence
    assert first_uuid == second_uuid
  end

  test "a thought mutation arms its cleanup lease before an ambiguous provider result", %{
    event: event
  } do
    previous = ReplyPresentation.new() |> ReplyPresentation.append_answer("正在运行")

    current =
      ReplyPresentation.apply_event(previous, "reasoning.delta", %{
        "operation_id" => "reasoning",
        "revision" => 2,
        "text" => "这段内容只能短暂可见"
      })

    checkpoint = %{
      "schema_version" => 1,
      "adapter" => "lark",
      "card_id" => "card-thought-window",
      "message_id" => "message-thought-window",
      "message_uuid" => "message-thought-window-uuid",
      "streaming_state" => "open",
      "stream_deadline_at" =>
        DateTime.utc_now(:microsecond) |> DateTime.add(540, :second) |> DateTime.to_iso8601(),
      "element_ids" => ["state", "answer"],
      "presentation" => ReplyPresentation.checkpoint(previous),
      "answer_content" => previous["answer"]
    }

    assert {:ok, stored} = Actors.put_reply_preview_checkpoint(event.id, checkpoint)

    request_fun = fn _client, :post, "cardkit/v1/cards/:card_id/batch_update", _opts ->
      {:error, :timeout}
    end

    assert {:error, :timeout} =
             CardKit.update(
               %Request{
                 actor_event: stored,
                 presentation: current,
                 previous_presentation: previous,
                 checkpoint: checkpoint,
                 mode: :working
               },
               client: :recording_client,
               request_fun: request_fun
             )

    persisted = Repo.get!(ActorEvent, event.id)
    assert "thought" in persisted.reply_preview_checkpoint["element_ids"]
    assert is_binary(persisted.reply_preview_checkpoint["cleanup_at"])
    assert %DateTime{} = persisted.reply_preview_cleanup_at
  end

  test "initial card send retries only the known card visibility race with the same message UUID",
       %{event: event} do
    presentation = ReplyPresentation.new() |> ReplyPresentation.append_answer("CardKit ready")
    parent = self()
    reply_attempts = :counters.new(1, [])

    request_fun = fn
      _client, :post, "cardkit/v1/cards", _opts ->
        {:ok, %{"data" => %{"card_id" => "card-new"}}}

      _client, :post, "im/v1/messages/:message_id/reply", opts ->
        :counters.add(reply_attempts, 1, 1)
        send(parent, {:card_send_attempt, opts[:body][:uuid]})

        if :counters.get(reply_attempts, 1) == 1 do
          {:error,
           %Error{
             code: 230_099,
             msg: "Failed to create card content; cardid is invalid"
           }}
        else
          {:ok, %{"data" => %{"message_id" => "message-new"}}}
        end
    end

    assert {:ok, result} =
             CardKit.open(
               %Request{
                 actor_event: event,
                 presentation: presentation,
                 subject_uid: event.agent_uid,
                 conversation_id: Ecto.UUID.generate(),
                 mode: :working
               },
               client: :recording_client,
               request_fun: request_fun,
               card_id_retry_delays_ms: [0],
               sleep_fun: fn delay -> send(parent, {:card_visibility_sleep, delay}) end
             )

    assert result.created_source_entry_id == "message-new"
    assert_receive {:card_visibility_sleep, 0}
    assert_receive {:card_send_attempt, first_uuid}
    assert_receive {:card_send_attempt, second_uuid}
    assert first_uuid == second_uuid
  end

  test "a withdrawn reply target posts the same CardKit reference as a new message", %{
    event: event
  } do
    presentation = ReplyPresentation.new() |> ReplyPresentation.append_answer("CardKit fallback")
    parent = self()

    request_fun = fn
      _client, :post, "cardkit/v1/cards", _opts ->
        {:ok, %{"data" => %{"card_id" => "card-target-gone"}}}

      _client, :post, "im/v1/messages/:message_id/reply", opts ->
        send(parent, {:reply_target_attempt, opts})
        {:error, %Error{code: 23_000, msg: "message was withdrawn"}}

      _client, :post, "im/v1/messages", opts ->
        send(parent, {:target_fallback_post, opts})
        {:ok, %{"data" => %{"message_id" => "message-target-fallback"}}}
    end

    assert {:ok, result} =
             CardKit.open(
               %Request{
                 actor_event: event,
                 presentation: presentation,
                 subject_uid: event.agent_uid,
                 conversation_id: Ecto.UUID.generate(),
                 mode: :working
               },
               client: :recording_client,
               request_fun: request_fun
             )

    assert_receive {:reply_target_attempt, reply_opts}
    assert reply_opts[:body][:reply_in_thread] == false

    assert_receive {:target_fallback_post, post_opts}
    assert post_opts[:body][:msg_type] == "interactive"
    assert post_opts[:body][:receive_id]
    assert result.created_source_entry_id == "message-target-fallback"
    assert result.delivered_operation == :post
  end

  test "cumulative answer growth uses CardKit's native element-content stream", %{event: event} do
    previous = ReplyPresentation.new() |> ReplyPresentation.append_answer("第一句。")
    current = ReplyPresentation.append_answer(previous, "第二句。")

    checkpoint = %{
      "schema_version" => 1,
      "adapter" => "lark",
      "card_id" => "card-content",
      "message_id" => "message-content",
      "message_uuid" => "message-content-uuid",
      "streaming_state" => "open",
      "element_ids" => ["state", "answer"],
      "presentation" => ReplyPresentation.checkpoint(previous),
      "answer_content" => previous["answer"]
    }

    assert {:ok, stored} = Actors.put_reply_preview_checkpoint(event.id, checkpoint)
    parent = self()

    request_fun = fn _client, method, path, opts ->
      send(parent, {:content_request, method, path, opts})
      {:ok, %{"data" => %{}}}
    end

    assert {:ok, result} =
             CardKit.update(
               %Request{
                 actor_event: stored,
                 presentation: current,
                 previous_presentation: previous,
                 checkpoint: checkpoint,
                 mode: :working
               },
               client: :recording_client,
               request_fun: request_fun
             )

    assert_receive {:content_request, :put,
                    "cardkit/v1/cards/:card_id/elements/:element_id/content", opts}

    assert opts[:path_params] == %{card_id: "card-content", element_id: "answer"}
    assert opts[:body][:content] == "第一句。第二句。"
    assert is_integer(opts[:body][:sequence])
    assert is_binary(opts[:body][:uuid])
    refute_receive {:content_request, :post, "cardkit/v1/cards/:card_id/batch_update", _opts}
    assert result.reply_preview_checkpoint["answer_content"] == current["answer"]
  end

  test "a growing tail page checkpoints its complete source for crash recovery", %{event: event} do
    previous =
      ReplyPresentation.new()
      |> ReplyPresentation.append_answer(String.duplicate("a", 12_500))

    current = ReplyPresentation.append_answer(previous, String.duplicate("b", 1_000))
    [first_page, previous_tail] = CardChain.pages(previous)
    [_current_first, current_tail] = CardChain.pages(current)

    first_card =
      CardChain.card_record(
        0,
        "card-growing-prefix",
        "card-growing-prefix-uuid",
        first_page,
        "sealed",
        ["state", "answer"]
      )
      |> Map.put("message_id", "message-growing-prefix")

    tail_card =
      CardChain.card_record(
        1,
        "card-growing-tail",
        "card-growing-tail-uuid",
        previous_tail,
        "open",
        ["state", "answer"]
      )
      |> Map.put("message_id", "message-growing-tail")

    checkpoint =
      %{
        "schema_version" => 1,
        "adapter" => "lark",
        "presentation" => ReplyPresentation.checkpoint(previous)
      }
      |> CardChain.initialize(first_card)
      |> CardChain.append(tail_card)

    assert {:ok, stored} = Actors.put_reply_preview_checkpoint(event.id, checkpoint)

    request_fun = fn _client,
                     :put,
                     "cardkit/v1/cards/:card_id/elements/:element_id/content",
                     opts ->
      assert opts[:body][:content] == current_tail.content
      {:ok, %{"data" => %{}}}
    end

    assert {:ok, result} =
             CardKit.update(
               %Request{
                 actor_event: stored,
                 presentation: current,
                 previous_presentation: previous,
                 checkpoint: checkpoint,
                 mode: :working
               },
               client: :recording_client,
               request_fun: request_fun
             )

    cards = result.reply_preview_checkpoint["cards"]
    assert Enum.map_join(cards, & &1["answer_source"]) == current["answer"]

    assert List.last(cards)["answer_end_byte"] == byte_size(current["answer"])
    assert List.last(cards)["answer_digest"] == CardChain.digest(current_tail.source)
  end

  test "terminal finalization closes an active text stream before updating final elements", %{
    event: event
  } do
    working = ReplyPresentation.new() |> ReplyPresentation.append_answer("生成中")
    terminal = ReplyPresentation.terminal(working, "completed", "最终答案")

    checkpoint = %{
      "schema_version" => 1,
      "adapter" => "lark",
      "card_id" => "card-terminal-order",
      "message_id" => "message-terminal-order",
      "message_uuid" => "message-terminal-order-uuid",
      "streaming_state" => "open",
      "element_ids" => ["state", "answer"],
      "presentation" => ReplyPresentation.checkpoint(working),
      "answer_content" => working["answer"]
    }

    assert {:ok, stored} = Actors.put_reply_preview_checkpoint(event.id, checkpoint)
    parent = self()

    request_fun = fn _client, :post, "cardkit/v1/cards/:card_id/batch_update", opts ->
      send(parent, {
        :terminal_batch,
        opts[:body][:sequence],
        opts[:body][:uuid],
        Ankole.JSON.decode!(opts[:body][:actions])
      })

      {:ok, %{"data" => %{}}}
    end

    assert {:ok, result} =
             CardKit.finalize(
               %Request{
                 actor_event: stored,
                 presentation: terminal,
                 previous_presentation: working,
                 checkpoint: checkpoint,
                 mode: :terminal
               },
               client: :recording_client,
               request_fun: request_fun
             )

    assert_receive {:terminal_batch, close_sequence, close_uuid, [close_action]}

    assert close_action["action"] == "partial_update_setting"
    assert get_in(close_action, ["params", "settings", "config", "streaming_mode"]) == false

    assert_receive {:terminal_batch, update_sequence, update_uuid, update_actions}
    assert update_sequence == close_sequence + 1
    refute update_uuid == close_uuid

    assert Enum.any?(update_actions, fn action ->
             action["action"] == "update_element" and
               get_in(action, ["params", "element_id"]) == "answer"
           end)

    refute Enum.any?(update_actions, &(&1["action"] == "partial_update_setting"))
    assert result.reply_preview_checkpoint["streaming_state"] == "closed"
    assert result.reply_preview_checkpoint["answer_content"] == "最终答案"
  end

  test "terminal finalization ignores a conservatively checkpointed element absent from Feishu",
       %{event: event} do
    previous =
      ReplyPresentation.new()
      |> ReplyPresentation.apply_event("tool.activity", %{
        "operation_id" => "ambiguous-tool",
        "revision" => 1,
        "phase" => "completed",
        "label" => "可能未落到卡片的活动"
      })

    terminal =
      previous
      |> ReplyPresentation.terminal("awaiting_input", "请选择路径")
      |> ReplyPresentation.apply_event("interaction.request", %{
        "operation_id" => "clarify-ambiguous",
        "revision" => 3,
        "prompt" => "请选择路径",
        "controls" => [
          %{
            "id" => "path-a",
            "type" => "button",
            "label" => "路径 A",
            "interaction_id" => "clarify-ambiguous",
            "source_actor_event_id" => event.id,
            "control_id" => "path",
            "selected_option_id" => "path-a",
            "option_value" => "A",
            "revision" => 3
          }
        ]
      })

    checkpoint = %{
      "schema_version" => 1,
      "adapter" => "lark",
      "card_id" => "card-missing-transient",
      "message_id" => "message-missing-transient",
      "message_uuid" => "message-missing-transient-uuid",
      "streaming_state" => "open",
      "element_ids" => ["state", "answer", "activity"],
      "presentation" => ReplyPresentation.checkpoint(previous),
      "answer_content" => " "
    }

    assert {:ok, stored} = Actors.put_reply_preview_checkpoint(event.id, checkpoint)
    parent = self()

    request_fun = fn _client, :post, "cardkit/v1/cards/:card_id/batch_update", opts ->
      actions = Ankole.JSON.decode!(opts[:body][:actions])
      send(parent, {:missing_transient_batch, opts[:body][:sequence], actions})

      if Enum.any?(actions, &(&1["action"] == "delete_elements")) do
        {:error,
         %Error{
           code: 300_314,
           msg: "not find elementID : activity",
           http_status: 200
         }}
      else
        {:ok, %{"data" => %{}}}
      end
    end

    assert {:ok, result} =
             CardKit.finalize(
               %Request{
                 actor_event: stored,
                 presentation: terminal,
                 previous_presentation: previous,
                 checkpoint: checkpoint,
                 mode: :terminal
               },
               client: :recording_client,
               request_fun: request_fun
             )

    assert_receive {:missing_transient_batch, close_sequence, [close_action]}
    assert close_action["action"] == "partial_update_setting"

    assert_receive {:missing_transient_batch, cleanup_sequence, [cleanup_action]}
    assert cleanup_sequence == close_sequence + 1
    assert cleanup_action["action"] == "delete_elements"

    assert_receive {:missing_transient_batch, individual_sequence, [individual_cleanup]}
    assert individual_sequence == cleanup_sequence + 1
    assert get_in(individual_cleanup, ["params", "element_ids"]) == ["activity"]

    assert_receive {:missing_transient_batch, terminal_sequence, terminal_actions}
    assert terminal_sequence == individual_sequence + 1
    refute Enum.any?(terminal_actions, &(&1["action"] == "delete_elements"))

    assert Enum.any?(terminal_actions, fn action ->
             action["action"] == "add_elements"
           end)

    assert result.reply_preview_checkpoint["streaming_state"] == "closed"
    assert result.reply_preview_checkpoint["presentation"]["state"] == "awaiting_input"
    assert result.reply_preview_checkpoint["presentation"]["actions"] != []
  end

  test "a thought-cleanup close is not mistaken for terminal delivery", %{event: event} do
    working = ReplyPresentation.new() |> ReplyPresentation.append_answer("仍在生成")
    terminal = ReplyPresentation.terminal(working, "completed", "最终答案")

    checkpoint = %{
      "schema_version" => 1,
      "adapter" => "lark",
      "card_id" => "card-cleanup-closed",
      "message_id" => "message-cleanup-closed",
      "message_uuid" => "message-cleanup-closed-uuid",
      "streaming_state" => "closed",
      "element_ids" => ["state", "answer"],
      "presentation" => ReplyPresentation.checkpoint(working),
      "answer_content" => working["answer"]
    }

    assert {:ok, stored} = Actors.put_reply_preview_checkpoint(event.id, checkpoint)
    parent = self()

    request_fun = fn _client, method, path, opts ->
      send(parent, {:terminal_request, method, path, opts})
      {:ok, %{"data" => %{}}}
    end

    assert {:ok, result} =
             CardKit.finalize(
               %Request{
                 actor_event: stored,
                 presentation: terminal,
                 previous_presentation: working,
                 checkpoint: checkpoint,
                 mode: :terminal
               },
               client: :recording_client,
               request_fun: request_fun
             )

    assert_receive {:terminal_request, :post, "cardkit/v1/cards/:card_id/batch_update", _opts}
    assert result.reply_preview_checkpoint["presentation"]["answer"] == "最终答案"
  end

  test "a durable terminal CardKit edit limit falls back to one new text message", %{
    event: event
  } do
    working = ReplyPresentation.new() |> ReplyPresentation.append_answer("生成中")
    terminal = ReplyPresentation.terminal(working, "completed", "最终答案")

    checkpoint = %{
      "schema_version" => 1,
      "adapter" => "lark",
      "card_id" => "card-edit-limit",
      "message_id" => "message-edit-limit",
      "message_uuid" => "message-edit-limit-uuid",
      "streaming_state" => "open",
      "element_ids" => ["state", "answer"],
      "presentation" => ReplyPresentation.checkpoint(working),
      "answer_content" => working["answer"]
    }

    assert {:ok, stored} = Actors.put_reply_preview_checkpoint(event.id, checkpoint)
    parent = self()

    request_fun = fn
      _client, :post, "cardkit/v1/cards/:card_id/batch_update", _opts ->
        {:error, %Error{code: 230_072, msg: "message edit limit reached"}}

      _client, :post, path, opts
      when path in ["im/v1/messages", "im/v1/messages/:message_id/reply"] ->
        send(parent, {:fallback_request, path, opts})
        {:ok, %{"data" => %{"message_id" => "message-fallback"}}}
    end

    outbox = %OutboxEntry{
      agent_uid: event.agent_uid,
      binding_name: event.binding_name,
      outbound_key: "ai-reply:terminal-edit-limit",
      idempotency_key: "ai-reply:terminal-edit-limit",
      operation: :edit,
      delivery_class: :durable_ai_reply,
      ai_message_id: Ecto.UUID.generate()
    }

    assert {:ok, result} =
             CardKit.finalize(
               %Request{
                 actor_event: stored,
                 presentation: terminal,
                 previous_presentation: working,
                 checkpoint: checkpoint,
                 outbox: outbox,
                 mode: :terminal
               },
               client: :recording_client,
               request_fun: request_fun
             )

    assert_receive {:fallback_request, _path, opts}
    assert opts[:body][:msg_type] == "text"
    assert Ankole.JSON.decode!(opts[:body][:content]) == %{"text" => "最终答案"}
    assert result.created_source_entry_id == "message-fallback"
  end

  test "a crash-ambiguous tail send resumes the same card and message UUID", %{event: event} do
    answer = String.duplicate("x", 13_000)
    terminal = ReplyPresentation.new() |> ReplyPresentation.terminal("completed", answer)
    parent = self()
    card_creates = :counters.new(1, [])
    message_sends = :counters.new(1, [])

    request_fun = fn
      _client, :post, "cardkit/v1/cards", _opts ->
        :counters.add(card_creates, 1, 1)
        index = :counters.get(card_creates, 1)
        {:ok, %{"data" => %{"card_id" => "card-resume-#{index}"}}}

      _client, :post, path, opts
      when path in ["im/v1/messages", "im/v1/messages/:message_id/reply"] ->
        :counters.add(message_sends, 1, 1)
        attempt = :counters.get(message_sends, 1)
        send(parent, {:tail_send_attempt, attempt, path, opts[:body][:uuid]})

        case attempt do
          1 -> {:ok, %{"data" => %{"message_id" => "message-resume-1"}}}
          2 -> {:error, :timeout}
          3 -> {:ok, %{"data" => %{"message_id" => "message-resume-2"}}}
        end

      _client, :post, "cardkit/v1/cards/:card_id/batch_update", _opts ->
        {:ok, %{"data" => %{}}}
    end

    request = %Request{
      actor_event: event,
      presentation: terminal,
      mode: :terminal
    }

    assert {:error, :timeout} =
             CardKit.finalize(request,
               client: :recording_client,
               request_fun: request_fun
             )

    interrupted = Repo.get!(ActorEvent, event.id).reply_preview_checkpoint
    assert interrupted["pending_rollover"]["phase"] == "send"
    assert interrupted["active_card_index"] == 1
    assert interrupted["message_id"] == nil

    assert {:ok, result} =
             CardKit.finalize(request,
               client: :recording_client,
               request_fun: request_fun
             )

    assert_receive {:tail_send_attempt, 1, first_path, _first_uuid}
    assert first_path =~ "/reply"
    assert_receive {:tail_send_attempt, 2, "im/v1/messages", first_tail_uuid}
    assert_receive {:tail_send_attempt, 3, "im/v1/messages", second_tail_uuid}
    assert first_tail_uuid == second_tail_uuid
    assert :counters.get(card_creates, 1) == 2
    refute result.reply_preview_checkpoint["pending_rollover"]
    assert result.reply_preview_checkpoint["message_id"] == "message-resume-2"
  end

  test "a long terminal answer stays in an ordered CardKit chain without loss", %{
    event: event
  } do
    answer = String.duplicate("长", 10_000)
    terminal = ReplyPresentation.new() |> ReplyPresentation.terminal("completed", answer)
    parent = self()
    card_attempts = :counters.new(1, [])
    message_attempts = :counters.new(1, [])
    page_count = terminal |> CardChain.pages() |> length()

    request_fun = fn
      _client, :post, "cardkit/v1/cards", opts ->
        :counters.add(card_attempts, 1, 1)
        index = :counters.get(card_attempts, 1)
        send(parent, {:created_card, index, Ankole.JSON.decode!(opts[:body][:data])})
        {:ok, %{"data" => %{"card_id" => "card-page-#{index}"}}}

      _client, :post, path, opts
      when path in ["im/v1/messages", "im/v1/messages/:message_id/reply"] ->
        :counters.add(message_attempts, 1, 1)
        index = :counters.get(message_attempts, 1)
        send(parent, {:sent_card, index, path, opts})
        {:ok, %{"data" => %{"message_id" => "message-page-#{index}"}}}
    end

    outbox = %OutboxEntry{
      agent_uid: event.agent_uid,
      binding_name: event.binding_name,
      outbound_key: "ai-reply:oversized",
      idempotency_key: "ai-reply:oversized",
      operation: :reply,
      delivery_class: :durable_ai_reply,
      ai_message_id: Ecto.UUID.generate()
    }

    assert {:ok, result} =
             CardKit.finalize(
               %Request{
                 actor_event: event,
                 presentation: terminal,
                 outbox: outbox,
                 mode: :terminal
               },
               client: :recording_client,
               request_fun: request_fun
             )

    cards =
      for index <- 1..page_count do
        assert_receive {:created_card, ^index, card}
        assert_receive {:sent_card, ^index, path, opts}
        if index == 1, do: assert(path =~ "/reply"), else: assert(path == "im/v1/messages")

        assert opts[:body][:msg_type] == "interactive"
        assert card["config"]["streaming_mode"] == false

        answer_element =
          Enum.find(get_in(card, ["body", "elements"]), &(&1["element_id"] == "answer"))

        {answer_element["content"], opts[:body][:uuid]}
      end

    assert cards |> Enum.map(&elem(&1, 0)) |> Enum.join() == answer
    assert cards |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() == page_count
    assert result.created_source_entry_id == "message-page-1"
    assert length(result.reply_preview_checkpoint["cards"]) == page_count

    assert result.reply_preview_checkpoint["cards"]
           |> Enum.map_join(& &1["answer_source"]) == answer
  end
end
