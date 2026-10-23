defmodule Ankole.Plugins.LarkAdapter.CardKitRecoveryTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures
  import Ankole.SignalsFixtures

  alias Ankole.Conversations.Delivery.PreviewState

  alias Ankole.Conversations.Delivery.PreviewStates
  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Cache, as: AppConfigureCache
  alias Ankole.AppConfigure.Registry, as: AppConfigureRegistry
  alias Ankole.Plugins.LarkAdapter.CardKit.CardChain
  alias Ankole.Plugins.LarkAdapter.CardKit.MarkdownSegmenter
  alias Ankole.Repo

  alias Ankole.Signals.Signal
  alias Ankole.Conversations.Delivery.Intent
  alias Ankole.Conversations.Delivery.ReplyPresentation
  alias Ankole.Conversations.Delivery.PreviewAdapter
  alias Ankole.Conversations.Delivery.PreviewAdapter.Request
  alias FeishuOpenAPI.Error

  defmodule CardKitHarness do
    @moduledoc false

    alias Ankole.Plugins.LarkAdapter.CardKit
    alias Ankole.Conversations.Delivery.PreviewAdapter
    alias FeishuOpenAPI.Error

    for operation <- [:update, :finalize, :refresh] do
      def unquote(operation)(request, opts) do
        run(unquote(operation), request, opts)
      end
    end

    defp run(operation, request, opts) do
      request_fun = Keyword.fetch!(opts, :request_fun)

      Req.default_options(
        retry_delay: fn _retry_count -> 0 end,
        retry_log_level: false,
        plug: fn conn -> dispatch(conn, request_fun) end
      )

      {:ok, adapter} = PreviewAdapter.from_module(CardKit)
      apply(PreviewAdapter, operation, [adapter, request])
    end

    defp dispatch(%{request_path: "/open-apis/auth/v3/tenant_access_token/internal"} = conn, _fun) do
      Req.Test.json(conn, %{
        "code" => 0,
        "tenant_access_token" => "tenant-token",
        "expire" => 7_200
      })
    end

    defp dispatch(conn, request_fun) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      {path, path_params} = request_path(conn.request_path)
      method = conn.method |> String.downcase() |> String.to_existing_atom()
      opts = [body: decode_body(body), path_params: path_params]

      case request_fun.(:recording_client, method, path, opts) do
        {:ok, response} ->
          Req.Test.json(conn, Map.put_new(response, "code", 0))

        {:error, :timeout} ->
          conn
          |> Plug.Conn.put_status(400)
          |> Req.Test.json(%{"code" => 300_120, "msg" => "simulated transport failure"})

        {:error, %Error{} = error} ->
          conn
          |> Plug.Conn.put_status(error.http_status || 400)
          |> Req.Test.json(%{"code" => error.code, "msg" => error.msg})
      end
    end

    defp request_path("/open-apis/cardkit/v1/cards"), do: {"cardkit/v1/cards", %{}}

    defp request_path("/open-apis/cardkit/v1/cards/" <> rest) do
      case String.split(rest, "/") do
        [card_id, "batch_update"] ->
          {"cardkit/v1/cards/:card_id/batch_update", %{card_id: card_id}}

        [card_id, "elements", element_id, "content"] ->
          {"cardkit/v1/cards/:card_id/elements/:element_id/content",
           %{card_id: card_id, element_id: element_id}}
      end
    end

    defp request_path("/open-apis/im/v1/messages"), do: {"im/v1/messages", %{}}

    defp request_path("/open-apis/im/v1/messages/" <> rest) do
      case String.split(rest, "/", parts: 2) do
        [message_id, "reply"] ->
          {"im/v1/messages/:message_id/reply", %{message_id: message_id}}

        [message_id] ->
          {"im/v1/messages/:message_id", %{message_id: message_id}}
      end
    end

    defp decode_body(""), do: %{}

    defp decode_body(body) do
      body
      |> Torque.decode!()
      |> Map.new(fn {key, value} -> {String.to_existing_atom(key), value} end)
    end
  end

  alias CardKitHarness, as: CardKit

  setup do
    Req.Test.set_req_test_to_shared()
    AppConfigureRegistry.clear_for_test()
    AppConfigureCache.clear_for_test()
    previous = Req.default_options()
    on_exit(fn -> Req.default_options(previous) end)

    config_id = "cardkit-recovery-#{System.unique_integer([:positive])}"

    assert {:ok, _config} =
             AppConfigure.put_global_by_key("signals.lark.bindings." <> config_id, %{
               "appID" => "cli_cardkit_test",
               "appSecret" => "secret"
             })

    %{principal: agent} = agent_fixture()

    assert {:ok, _binding} =
             Ankole.SignalsFixtures.raw_binding_fixture(%{
               agent_uid: agent.uid,
               name: "lark-cardkit",
               adapter: "lark",
               config_ref: "app-config://#{"signals.lark.bindings." <> config_id}",
               filters: %{},
               unaddressed_group_message_policy: :ignore,
               unmatched_sender_policy: :create_standalone
             })

    %{signal: event} =
      emit_addressed_signal(
        agent.uid,
        "lark-cardkit",
        group_entry(%{
          source_event_id: unique_uid("cardkit-event"),
          provider_message_id: unique_uid("cardkit-trigger"),
          explicit: true
        })
      )

    %{event: event}
  end

  test "restart refresh replaces the existing message with one complete closed card",
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

    assert {:ok, stored} =
             PreviewStates.put_checkpoint(event.id, checkpoint)

    parent = self()

    request_fun = fn _client, :patch, "im/v1/messages/:message_id", opts ->
      send(parent, {:message_rebuilt, opts})
      {:ok, %{"data" => %{"message_id" => "message-recovered"}}}
    end

    assert {:ok, result} =
             CardKit.refresh(
               %Request{
                 signal: stored,
                 presentation: presentation,
                 previous_presentation: checkpoint["presentation"],
                 checkpoint: checkpoint,
                 mode: :working
               },
               client: :recording_client,
               request_fun: request_fun
             )

    assert_receive {:message_rebuilt, patch_opts}
    assert patch_opts[:path_params] == %{message_id: "message-recovered"}
    assert Map.keys(patch_opts[:body]) == [:content]
    card = Ankole.JSON.decode!(patch_opts[:body][:content])
    assert card["config"]["streaming_mode"] == false
    refute Enum.any?(card["body"]["elements"], &(&1["element_id"] == "thought"))

    refute_receive {:cardkit_request, :post, "cardkit/v1/cards", _opts}
    refute_receive {:cardkit_request, :post, "cardkit/v1/cards/:card_id/batch_update", _opts}

    assert result.created_provider_message_id == "message-recovered"

    assert result.reply_preview_checkpoint["card_id"] ==
             "card-recovered"

    assert result.reply_preview_checkpoint["message_id"] ==
             "message-recovered"

    assert get_in(result.reply_preview_checkpoint, [
             "cards",
             Access.at(0),
             "transport"
           ]) ==
             "inline_message"

    assert result.reply_preview_checkpoint["streaming_state"] ==
             "closed"

    assert result.reply_preview_checkpoint["stream_deadline_at"] ==
             nil

    refute result.reply_preview_checkpoint["refresh_pending"]
    refute result.reply_preview_checkpoint["cleanup_at"]

    persisted = Repo.get!(Signal, event.id)

    assert Ankole.Conversations.Delivery.PreviewStates.get(persisted).checkpoint[
             "streaming_state"
           ] ==
             "closed"
  end

  test "terminal recovery uses the durable intent presentation instead of the stale checkpoint",
       %{event: event} do
    working = ReplyPresentation.new() |> ReplyPresentation.append_answer("正在理解请求")

    terminal =
      working
      |> ReplyPresentation.terminal("failed", "AI 服务返回了错误，请重试。")

    [page] = CardChain.pages(working)

    checkpoint =
      %{
        "schema_version" => 1,
        "adapter" => "lark",
        "subject_uid" => event.agent_uid,
        "conversation_id" => Ecto.UUID.generate(),
        "presentation" => ReplyPresentation.checkpoint(working),
        "refresh_pending" => true,
        "refresh_reason" => "terminal_recovery"
      }
      |> CardChain.initialize(
        CardChain.card_record(
          0,
          "card-terminal-recovery",
          "card-terminal-recovery-uuid",
          page,
          "open",
          ["state", "answer"]
        )
      )

    assert {:ok, stored} =
             PreviewStates.put_checkpoint(event.id, checkpoint)

    parent = self()

    request_fun = fn
      _client, :post, path, opts
      when path in ["im/v1/messages", "im/v1/messages/:message_id/reply"] ->
        send(parent, {:terminal_reference_sent, opts})
        {:ok, %{"data" => %{"message_id" => "message-terminal-recovery"}}}

      _client, :patch, "im/v1/messages/:message_id", opts ->
        send(parent, {:terminal_message_patched, opts})
        {:ok, %{"data" => %{}}}
    end

    assert {:ok, result} =
             CardKit.refresh(
               %Request{
                 signal: stored,
                 presentation: terminal,
                 previous_presentation: checkpoint["presentation"],
                 checkpoint: checkpoint,
                 mode: :terminal
               },
               client: :recording_client,
               request_fun: request_fun
             )

    assert_receive {:terminal_reference_sent, _opts}
    assert_receive {:terminal_message_patched, patch_opts}
    card = Ankole.JSON.decode!(patch_opts[:body][:content])
    answer = Enum.find(card["body"]["elements"], &(&1["element_id"] == "answer"))
    assert answer["content"] == "AI 服务返回了错误，请重试。"

    assert result.reply_preview_checkpoint["presentation"][
             "state"
           ] == "failed"

    assert result.reply_preview_checkpoint["streaming_state"] ==
             "closed"
  end

  test "terminal recovery returns a non-retry fallback when the provider rejects a card reference",
       %{event: event} do
    working = ReplyPresentation.new() |> ReplyPresentation.append_answer("正在理解请求")
    terminal = working |> ReplyPresentation.terminal("failed", "最终错误")
    [page] = CardChain.pages(working)

    checkpoint =
      %{
        "schema_version" => 1,
        "adapter" => "lark",
        "subject_uid" => event.agent_uid,
        "conversation_id" => Ecto.UUID.generate(),
        "presentation" => ReplyPresentation.checkpoint(working),
        "refresh_pending" => true,
        "refresh_reason" => "terminal_recovery"
      }
      |> CardChain.initialize(
        CardChain.card_record(
          0,
          "card-terminal-binding-limit",
          "card-terminal-binding-limit-uuid",
          page,
          "open",
          ["state", "answer"]
        )
      )

    assert {:ok, stored} =
             PreviewStates.put_checkpoint(event.id, checkpoint)

    request_fun = fn _client, :post, path, _opts
                     when path in ["im/v1/messages", "im/v1/messages/:message_id/reply"] ->
      {:error,
       %Error{
         code: 230_099,
         msg:
           "Failed to create card content; ErrCode: 200780; ErrMsg: card binding biz count over limit",
         http_status: 400
       }}
    end

    assert {:error,
            {:degraded, :plain_text,
             %{
               "code" => 230_099,
               "message" => message
             }}} =
             CardKit.refresh(
               %Request{
                 signal: stored,
                 presentation: terminal,
                 previous_presentation: checkpoint["presentation"],
                 checkpoint: checkpoint,
                 mode: :terminal
               },
               client: :recording_client,
               request_fun: request_fun
             )

    assert message =~ "card binding biz count over limit"
  end

  test "a refreshed answer over the page table budget completes the card chain", %{event: event} do
    answer =
      Enum.map_join(1..6, "\n\n", fn index ->
        "| 指标#{index} | 值 |\n| --- | --- |\n| a | #{index} |"
      end)

    presentation = ReplyPresentation.terminal(ReplyPresentation.new(), "completed", answer)

    checkpoint = %{
      "schema_version" => 1,
      "adapter" => "lark",
      "card_id" => "card-blocked",
      "message_id" => "message-blocked",
      "message_uuid" => "message-uuid",
      "streaming_state" => "open",
      "stream_deadline_at" => "2026-07-14T02:00:00.000000Z",
      "element_ids" => ["state", "answer"],
      "presentation" => ReplyPresentation.checkpoint(presentation),
      "refresh_pending" => true,
      "refresh_reason" => "terminal_recovery"
    }

    assert {:ok, stored} =
             PreviewStates.put_checkpoint(event.id, checkpoint)

    parent = self()

    request_fun = fn
      _client, :patch, "im/v1/messages/:message_id", opts ->
        send(parent, {:patched, opts})
        {:ok, %{"data" => %{"message_id" => opts[:path_params][:message_id]}}}

      _client, :post, "cardkit/v1/cards", opts ->
        send(parent, {:card_created, opts})
        {:ok, %{"data" => %{"card_id" => "card-tail"}}}

      _client, :post, "im/v1/messages/:message_id/reply", opts ->
        send(parent, {:tail_sent, opts})
        {:ok, %{"data" => %{"message_id" => "message-tail"}}}

      _client, :post, "im/v1/messages", opts ->
        send(parent, {:tail_sent, opts})
        {:ok, %{"data" => %{"message_id" => "message-tail"}}}
    end

    assert {:ok, _result} =
             CardKit.refresh(
               %Request{
                 signal: stored,
                 presentation: presentation,
                 previous_presentation: checkpoint["presentation"],
                 checkpoint: checkpoint,
                 mode: :terminal
               },
               client: :recording_client,
               request_fun: request_fun
             )

    assert_receive {:patched, patch_opts}
    assert patch_opts[:path_params] == %{message_id: "message-blocked"}
    sealed_card = Ankole.JSON.decode!(patch_opts[:body][:content])

    sealed_answer =
      Enum.find(get_in(sealed_card, ["body", "elements"]), &(&1["element_id"] == "answer"))

    assert MarkdownSegmenter.count_tables(sealed_answer["content"]) == 4

    assert_receive {:card_created, _create_opts}
    assert_receive {:tail_sent, _send_opts}

    refreshed =
      event.id
      |> then(&Ankole.Conversations.Delivery.PreviewStates.get(Repo.get!(Signal, &1)).checkpoint)
      |> PreviewAdapter.adapter_checkpoint()

    cards = CardChain.cards(refreshed)
    assert length(cards) == 2
    assert Enum.map_join(cards, & &1["answer_source"]) == answer
    assert Enum.all?(cards, &(&1["streaming_state"] == "closed"))
    assert refreshed["streaming_state"] == "closed"
    refute Map.has_key?(refreshed, "refresh_pending")
  end

  test "refresh freezes an accepted answer by replacing the same message", %{
    event: event
  } do
    pending =
      ReplyPresentation.new()
      |> ReplyPresentation.append_answer("请选择路径")
      |> ReplyPresentation.apply_event("interaction.request", %{
        "revision" => 1,
        "prompt" => "请选择路径",
        "controls" => [
          %{
            "id" => "path-a",
            "type" => "button",
            "label" => "路径 A",
            "interaction_id" => "clarify:missing-actions",
            "source_signal_id" => event.id,
            "control_id" => "path",
            "selected_option_id" => "path-a",
            "option_value" => "A",
            "revision" => 1
          },
          %{
            "id" => "path-other",
            "type" => "form",
            "label" => "其他",
            "interaction_id" => "clarify:missing-actions",
            "source_signal_id" => event.id,
            "control_id" => "path-other",
            "revision" => 1,
            "fields" => [
              %{
                "id" => "path-other-answer",
                "type" => "input",
                "label" => "其他路径",
                "required" => true
              }
            ]
          }
        ]
      })

    answered =
      ReplyPresentation.resolve_interaction(pending, "answered", %{
        "kind" => "free_text",
        "interaction_id" => "clarify:missing-actions",
        "value" => "路径 C"
      })

    checkpoint = %{
      "schema_version" => 1,
      "adapter" => "lark",
      "card_id" => "card-missing-actions",
      "message_id" => "message-missing-actions",
      "message_uuid" => "message-missing-actions-uuid",
      "streaming_state" => "closed",
      "element_ids" => ["state", "answer"],
      "presentation" => ReplyPresentation.checkpoint(answered),
      "previous_presentation" => ReplyPresentation.checkpoint(pending),
      "answer_content" => "请选择路径",
      "refresh_pending" => true,
      "refresh_reason" => "interaction_answered"
    }

    assert {:ok, stored} =
             PreviewStates.put_checkpoint(event.id, checkpoint)

    parent = self()

    request_fun = fn _client, :patch, "im/v1/messages/:message_id", opts ->
      send(parent, {:interactive_message_rebuilt, opts})
      {:ok, %{"data" => %{"message_id" => "message-missing-actions"}}}
    end

    assert {:ok, result} =
             CardKit.refresh(
               %Request{
                 signal: stored,
                 presentation: answered,
                 previous_presentation: pending,
                 checkpoint: checkpoint,
                 mode: :terminal
               },
               client: :recording_client,
               request_fun: request_fun
             )

    assert_receive {:interactive_message_rebuilt, patch_opts}
    assert patch_opts[:path_params] == %{message_id: "message-missing-actions"}
    card = Ankole.JSON.decode!(patch_opts[:body][:content])
    elements = card["body"]["elements"]
    refute Enum.any?(elements, &(&1["element_id"] == "actions"))

    receipt = Enum.find(elements, &(&1["element_id"] == "interaction_answer"))

    assert [%{"elements" => [_label, %{"text" => %{"content" => "路径 C"}}]}] =
             receipt["columns"]

    refute result.reply_preview_checkpoint["refresh_pending"]

    assert result.reply_preview_checkpoint["card_id"] ==
             "card-missing-actions"

    assert result.reply_preview_checkpoint["message_id"] ==
             "message-missing-actions"

    assert get_in(result.reply_preview_checkpoint, [
             "cards",
             Access.at(0),
             "transport"
           ]) ==
             "inline_message"

    assert "interaction_answer" in result.reply_preview_checkpoint[
             "element_ids"
           ]

    refute "actions" in result.reply_preview_checkpoint[
             "element_ids"
           ]
  end

  test "a consumed UUID acknowledges an ambiguous CardKit mutation retry", %{event: event} do
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
      "answer_content" => presentation["answer"]
    }

    current =
      ReplyPresentation.apply_event(presentation, "tool.activity", %{
        "operation_id" => "read",
        "revision" => 1,
        "phase" => "running",
        "label" => "读取网页"
      })

    assert {:ok, stored} =
             PreviewStates.put_checkpoint(event.id, checkpoint)

    attempts = :counters.new(1, [])
    parent = self()

    request_fun = fn _client, :post, "cardkit/v1/cards/:card_id/batch_update", opts ->
      :counters.add(attempts, 1, 1)
      send(parent, {:mutation_attempt, opts[:body][:sequence], opts[:body][:uuid]})

      case :counters.get(attempts, 1) do
        1 -> {:error, :timeout}
        2 -> {:error, %Error{code: 300_317, msg: "sequence number compare failed"}}
        _later_mutation -> {:ok, %{"data" => %{}}}
      end
    end

    request = %Request{
      signal: stored,
      presentation: current,
      previous_presentation: checkpoint["presentation"],
      checkpoint: checkpoint,
      mode: :working
    }

    assert {:error, {:reply_delivery, :retryable, _provider_error}} =
             CardKit.update(request,
               client: :recording_client,
               request_fun: request_fun
             )

    assert {:ok, result} =
             CardKit.update(request,
               client: :recording_client,
               request_fun: request_fun
             )

    assert_receive {:mutation_attempt, first_sequence, first_uuid}
    assert_receive {:mutation_attempt, second_sequence, second_uuid}
    assert first_sequence == second_sequence
    assert first_uuid == second_uuid
    assert_receive {:mutation_attempt, third_sequence, third_uuid}
    assert third_sequence > second_sequence
    refute third_uuid == second_uuid
    refute result.reply_preview_checkpoint["pending_mutation"]
  end

  test "a live topology conflict rebuilds the latest active card without posting another message",
       %{
         event: event
       } do
    previous = ReplyPresentation.new() |> ReplyPresentation.append_answer("正在运行")

    current =
      ReplyPresentation.apply_event(previous, "tool.activity", %{
        "operation_id" => "search",
        "revision" => 1,
        "phase" => "running",
        "label" => "检索资料"
      })

    checkpoint = %{
      "schema_version" => 1,
      "adapter" => "lark",
      "card_id" => "card-live",
      "message_id" => "message-live",
      "message_uuid" => "message-live-uuid",
      "streaming_state" => "open",
      "stream_deadline_at" =>
        DateTime.utc_now(:microsecond) |> DateTime.add(540, :second) |> DateTime.to_iso8601(),
      "element_ids" => ["state", "separator", "answer"],
      "presentation" => ReplyPresentation.checkpoint(previous),
      "answer_content" => previous["answer"]
    }

    assert {:ok, stored} =
             PreviewStates.put_checkpoint(event.id, checkpoint)

    parent = self()

    latest_checkpoint = %{
      checkpoint
      | "card_id" => "card-latest",
        "message_id" => "message-latest"
    }

    request_fun = fn
      _client, :post, "cardkit/v1/cards/:card_id/batch_update", _opts ->
        assert {:ok, _event} =
                 PreviewStates.put_checkpoint(
                   event.id,
                   latest_checkpoint
                 )

        send(parent, :topology_conflict)
        {:error, %Error{code: 300_301, msg: "ElementID separator: Duplicate ID"}}

      _client, :patch, "im/v1/messages/:message_id", opts ->
        send(parent, {:live_message_rebuilt, opts})
        {:ok, %{"data" => %{"message_id" => "message-latest"}}}
    end

    assert {:ok, result} =
             CardKit.update(
               %Request{
                 signal: stored,
                 presentation: current,
                 previous_presentation: previous,
                 checkpoint: checkpoint,
                 mode: :working
               },
               client: :recording_client,
               request_fun: request_fun
             )

    assert_receive :topology_conflict
    assert_receive {:live_message_rebuilt, patch_opts}
    assert patch_opts[:path_params] == %{message_id: "message-latest"}
    assert result.created_provider_message_id == "message-latest"

    assert result.reply_preview_checkpoint["card_id"] ==
             "card-latest"

    assert result.reply_preview_checkpoint["message_id"] ==
             "message-latest"

    assert get_in(result.reply_preview_checkpoint, [
             "cards",
             Access.at(0),
             "transport"
           ]) ==
             "inline_message"

    refute_receive {:cardkit_request, :post, "im/v1/messages", _opts}
    refute_receive {:cardkit_request, :post, "im/v1/messages/:message_id/reply", _opts}

    continued = ReplyPresentation.append_answer(current, "\n恢复后继续输出")
    recovered_event = Repo.get!(Signal, event.id)

    assert {:ok, continued_result} =
             CardKit.update(
               %Request{
                 signal: recovered_event,
                 presentation: continued,
                 previous_presentation: current,
                 checkpoint: result.reply_preview_checkpoint,
                 mode: :working
               },
               client: :recording_client,
               request_fun: request_fun
             )

    assert_receive {:live_message_rebuilt, continued_opts}
    continued_card = Ankole.JSON.decode!(continued_opts[:body][:content])
    answer = Enum.find(continued_card["body"]["elements"], &(&1["element_id"] == "answer"))
    assert answer["content"] =~ "恢复后继续输出"

    assert continued_result.reply_preview_checkpoint[
             "answer_content"
           ] =~ "恢复后继续输出"

    refute_receive {:cardkit_request, :post, "cardkit/v1/cards/:card_id/batch_update", _opts}
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

    assert {:ok, stored} =
             PreviewStates.put_checkpoint(event.id, checkpoint)

    request_fun = fn _client, :post, "cardkit/v1/cards/:card_id/batch_update", _opts ->
      {:error, :timeout}
    end

    assert {:error, {:reply_delivery, :retryable, _provider_error}} =
             CardKit.update(
               %Request{
                 signal: stored,
                 presentation: current,
                 previous_presentation: previous,
                 checkpoint: checkpoint,
                 mode: :working
               },
               client: :recording_client,
               request_fun: request_fun
             )

    persisted = Repo.get!(Signal, event.id)

    checkpoint =
      PreviewAdapter.adapter_checkpoint(
        Ankole.Conversations.Delivery.PreviewStates.get(persisted).checkpoint
      )

    assert "thought" in checkpoint["element_ids"]
    assert is_binary(checkpoint["cleanup_at"])
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
             CardKit.update(
               %Request{
                 signal: event,
                 presentation: presentation,
                 subject_uid: event.agent_uid,
                 conversation_id: Ecto.UUID.generate(),
                 mode: :working
               },
               client: :recording_client,
               request_fun: request_fun
             )

    assert result.created_provider_message_id == "message-new"
    assert_receive {:card_send_attempt, first_uuid}
    assert_receive {:card_send_attempt, second_uuid}
    assert first_uuid == second_uuid
  end

  @tag :cardkit_r03
  test "a source conflict keeps the sent card checkpoint and its original error on recovery", %{
    event: event
  } do
    presentation = ReplyPresentation.new() |> ReplyPresentation.append_answer("Sent once")
    requests = :counters.new(2, [])

    request_fun = fn
      _client, :post, "cardkit/v1/cards", _opts ->
        :counters.add(requests, 1, 1)
        {:ok, %{"data" => %{"card_id" => "card-source-conflict"}}}

      _client, :post, "im/v1/messages/:message_id/reply", _opts ->
        :counters.add(requests, 2, 1)

        assert :ok =
                 PreviewStates.record_provider_message(
                   event.id,
                   "first-source-wins"
                 )

        {:ok, %{"data" => %{"message_id" => "message-source-conflict"}}}

      _client, :post, "cardkit/v1/cards/:card_id/batch_update", _opts ->
        {:ok, %{"data" => %{}}}
    end

    request = %Request{
      signal: event,
      presentation: presentation,
      subject_uid: event.agent_uid,
      conversation_id: Ecto.UUID.generate(),
      mode: :working
    }

    assert {:error, :reply_preview_source_entry_already_recorded} =
             CardKit.update(request, client: :recording_client, request_fun: request_fun)

    persisted = Repo.reload!(event)

    checkpoint =
      PreviewAdapter.adapter_checkpoint(
        Ankole.Conversations.Delivery.PreviewStates.get(persisted).checkpoint
      )

    assert Ankole.Conversations.Delivery.PreviewStates.get(persisted).provider_message_id ==
             "first-source-wins"

    assert checkpoint["card_id"] == "card-source-conflict"
    assert checkpoint["message_id"] == "message-source-conflict"

    assert {:ok, _result} =
             CardKit.update(
               %{request | signal: persisted, checkpoint: checkpoint},
               client: :recording_client,
               request_fun: request_fun
             )

    assert :counters.get(requests, 1) == 1
    assert :counters.get(requests, 2) == 1

    assert Ankole.Conversations.Delivery.PreviewStates.get(Repo.reload!(event)).provider_message_id ==
             "first-source-wins"
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
             CardKit.update(
               %Request{
                 signal: event,
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
    assert result.created_provider_message_id == "message-target-fallback"
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

    assert {:ok, stored} =
             PreviewStates.put_checkpoint(event.id, checkpoint)

    parent = self()

    request_fun = fn _client, method, path, opts ->
      send(parent, {:content_request, method, path, opts})
      {:ok, %{"data" => %{}}}
    end

    assert {:ok, result} =
             CardKit.update(
               %Request{
                 signal: stored,
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

    assert result.reply_preview_checkpoint["answer_content"] ==
             current["answer"]
  end

  test "a consumed UUID acknowledges an ambiguous content-stream retry", %{event: event} do
    previous = ReplyPresentation.new() |> ReplyPresentation.append_answer("第一句。")
    current = ReplyPresentation.append_answer(previous, "第二句。")

    checkpoint = %{
      "schema_version" => 1,
      "adapter" => "lark",
      "card_id" => "card-content-retry",
      "message_id" => "message-content-retry",
      "message_uuid" => "message-content-retry-uuid",
      "streaming_state" => "open",
      "element_ids" => ["state", "answer"],
      "presentation" => ReplyPresentation.checkpoint(previous),
      "answer_content" => previous["answer"]
    }

    assert {:ok, stored} =
             PreviewStates.put_checkpoint(event.id, checkpoint)

    attempts = :counters.new(1, [])
    parent = self()

    request_fun = fn _client,
                     :put,
                     "cardkit/v1/cards/:card_id/elements/:element_id/content",
                     opts ->
      :counters.add(attempts, 1, 1)
      send(parent, {:content_retry, opts[:body][:sequence], opts[:body][:uuid]})

      if :counters.get(attempts, 1) == 1,
        do: {:error, :timeout},
        else: {:error, %Error{code: 200_770, msg: "this UUID has been recently consumed"}}
    end

    request = %Request{
      signal: stored,
      presentation: current,
      previous_presentation: previous,
      checkpoint: checkpoint,
      mode: :working
    }

    assert {:error, {:reply_delivery, :retryable, _provider_error}} =
             CardKit.update(request,
               client: :recording_client,
               request_fun: request_fun
             )

    assert {:ok, result} =
             CardKit.update(request,
               client: :recording_client,
               request_fun: request_fun
             )

    assert_receive {:content_retry, first_sequence, first_uuid}
    assert_receive {:content_retry, second_sequence, second_uuid}
    assert first_sequence == second_sequence
    assert first_uuid == second_uuid

    assert result.reply_preview_checkpoint["answer_content"] ==
             current["answer"]

    refute result.reply_preview_checkpoint["pending_mutation"]
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

    assert {:ok, stored} =
             PreviewStates.put_checkpoint(event.id, checkpoint)

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
                 signal: stored,
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

  test "terminal finalization replaces an active stream with one closed message card", %{
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

    assert {:ok, stored} =
             PreviewStates.put_checkpoint(event.id, checkpoint)

    parent = self()

    request_fun = fn _client, :patch, "im/v1/messages/:message_id", opts ->
      send(parent, {:terminal_patch, opts})
      {:ok, %{"data" => %{}}}
    end

    assert {:ok, result} =
             CardKit.finalize(
               %Request{
                 signal: stored,
                 presentation: terminal,
                 previous_presentation: working,
                 checkpoint: checkpoint,
                 mode: :terminal
               },
               client: :recording_client,
               request_fun: request_fun
             )

    assert_receive {:terminal_patch, opts}
    assert opts[:path_params] == %{message_id: "message-terminal-order"}
    card = Ankole.JSON.decode!(opts[:body][:content])
    assert card["config"]["streaming_mode"] == false

    assert get_in(card, ["body", "elements"]) == [
             %{"tag" => "markdown", "element_id" => "answer", "content" => "最终答案"}
           ]

    refute_receive {:terminal_patch, _opts}

    assert result.reply_preview_checkpoint["streaming_state"] ==
             "closed"

    assert result.reply_preview_checkpoint["answer_content"] ==
             "最终答案"

    assert get_in(result.reply_preview_checkpoint, [
             "cards",
             Access.at(0),
             "transport"
           ]) ==
             "inline_message"
  end

  test "whole-card finalization ignores stale checkpoint element topology",
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
      ReplyPresentation.new()
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
            "source_signal_id" => event.id,
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

    assert {:ok, stored} =
             PreviewStates.put_checkpoint(event.id, checkpoint)

    parent = self()

    request_fun = fn _client, :patch, "im/v1/messages/:message_id", opts ->
      send(parent, {:terminal_patch, opts})
      {:ok, %{"data" => %{}}}
    end

    assert {:ok, result} =
             CardKit.finalize(
               %Request{
                 signal: stored,
                 presentation: terminal,
                 previous_presentation: previous,
                 checkpoint: checkpoint,
                 mode: :terminal
               },
               client: :recording_client,
               request_fun: request_fun
             )

    assert_receive {:terminal_patch, opts}
    card = Ankole.JSON.decode!(opts[:body][:content])
    assert card["config"]["streaming_mode"] == false
    assert Enum.any?(get_in(card, ["body", "elements"]), &(&1["element_id"] == "actions"))
    refute Enum.any?(get_in(card, ["body", "elements"]), &(&1["element_id"] == "activity"))

    assert result.reply_preview_checkpoint["streaming_state"] ==
             "closed"

    assert result.reply_preview_checkpoint["presentation"][
             "state"
           ] == "awaiting_input"

    assert result.reply_preview_checkpoint["presentation"][
             "actions"
           ] != []

    assert get_in(result.reply_preview_checkpoint, [
             "cards",
             Access.at(0),
             "transport"
           ]) ==
             "inline_message"
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

    assert {:ok, stored} =
             PreviewStates.put_checkpoint(event.id, checkpoint)

    parent = self()

    request_fun = fn _client, method, path, opts ->
      send(parent, {:terminal_request, method, path, opts})
      {:ok, %{"data" => %{}}}
    end

    assert {:ok, result} =
             CardKit.finalize(
               %Request{
                 signal: stored,
                 presentation: terminal,
                 previous_presentation: working,
                 checkpoint: checkpoint,
                 mode: :terminal
               },
               client: :recording_client,
               request_fun: request_fun
             )

    assert_receive {:terminal_request, :patch, "im/v1/messages/:message_id", _opts}

    assert result.reply_preview_checkpoint["presentation"][
             "answer"
           ] == "最终答案"
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

    assert {:ok, stored} =
             PreviewStates.put_checkpoint(event.id, checkpoint)

    parent = self()

    request_fun = fn
      _client, :patch, "im/v1/messages/:message_id", _opts ->
        {:error, %Error{code: 230_072, msg: "message edit limit reached"}}

      _client, :post, path, opts
      when path in ["im/v1/messages", "im/v1/messages/:message_id/reply"] ->
        send(parent, {:fallback_request, path, opts})
        {:ok, %{"data" => %{"message_id" => "message-fallback"}}}
    end

    intent = %Intent{
      agent_uid: event.agent_uid,
      binding_name: event.reply_binding_name,
      outbound_key: "ai-reply:terminal-edit-limit",
      idempotency_key: "ai-reply:terminal-edit-limit",
      operation: :edit,
      delivery_class: :durable_ai_reply,
      ai_message_id: Ecto.UUID.generate()
    }

    assert {:ok, result} =
             CardKit.finalize(
               %Request{
                 signal: stored,
                 presentation: terminal,
                 previous_presentation: working,
                 checkpoint: checkpoint,
                 delivery: intent,
                 mode: :terminal
               },
               client: :recording_client,
               request_fun: request_fun
             )

    assert_receive {:fallback_request, _path, opts}
    assert opts[:body][:msg_type] == "text"
    assert Ankole.JSON.decode!(opts[:body][:content]) == %{"text" => "最终答案"}
    assert result.created_provider_message_id == "message-fallback"
  end

  test "a provider page-binding limit posts only the unsent tail as plain text", %{
    event: event
  } do
    answer = String.duplicate("x", 13_000)
    terminal = ReplyPresentation.new() |> ReplyPresentation.terminal("completed", answer)
    [first_page, tail_page] = CardChain.pages(terminal)

    first_card =
      CardChain.card_record(
        0,
        "card-binding-prefix",
        "card-binding-prefix-uuid",
        first_page,
        "sealed",
        ["answer"]
      )
      |> Map.put("message_id", "message-binding-prefix")

    tail_card =
      CardChain.card_record(
        1,
        "card-binding-tail",
        "card-binding-tail-uuid",
        tail_page,
        "closed",
        ["answer"]
      )

    checkpoint =
      %{
        "schema_version" => 1,
        "adapter" => "lark",
        "presentation" => ReplyPresentation.checkpoint(terminal),
        "subject_uid" => event.agent_uid,
        "conversation_id" => Ecto.UUID.generate()
      }
      |> CardChain.initialize(first_card)
      |> CardChain.append(tail_card)
      |> Map.put("pending_rollover", %{
        "from_index" => 0,
        "to_index" => 1,
        "phase" => "send",
        "answer_digest" => CardChain.digest(tail_page.source),
        "message_uuid" => tail_card["message_uuid"]
      })

    assert {:ok, stored} =
             PreviewStates.put_checkpoint(event.id, checkpoint)

    parent = self()

    request_fun = fn
      _client, :post, "im/v1/messages", opts ->
        case opts[:body][:msg_type] do
          "interactive" ->
            send(parent, {:binding_limited_card, opts})

            {:error,
             %Error{
               code: 230_099,
               msg:
                 "Failed to create card content; ErrCode: 200780; ErrMsg: card binding biz count over limit",
               http_status: 400
             }}

          "text" ->
            send(parent, {:binding_tail_fallback, opts})
            {:ok, %{"data" => %{"message_id" => "message-binding-tail-fallback"}}}
        end
    end

    intent = %Intent{
      agent_uid: event.agent_uid,
      binding_name: event.reply_binding_name,
      outbound_key: "ai-reply:binding-limit",
      idempotency_key: "ai-reply:binding-limit",
      operation: :reply,
      delivery_class: :durable_ai_reply,
      ai_message_id: Ecto.UUID.generate()
    }

    assert {:ok, result} =
             CardKit.finalize(
               %Request{
                 signal: stored,
                 presentation: terminal,
                 checkpoint: checkpoint,
                 delivery: intent,
                 mode: :terminal
               },
               client: :recording_client,
               request_fun: request_fun
             )

    assert_receive {:binding_limited_card, card_opts}
    assert card_opts[:body][:msg_type] == "interactive"

    assert_receive {:binding_tail_fallback, fallback_opts}
    assert fallback_opts[:body][:msg_type] == "text"
    assert fallback_opts[:body][:receive_id]

    assert %{"text" => delivered_tail} = Ankole.JSON.decode!(fallback_opts[:body][:content])
    assert delivered_tail == tail_page.source
    assert first_page.source <> delivered_tail == answer
    assert result.created_provider_message_id == "message-binding-tail-fallback"
    assert result.delivered_operation == :post
  end

  test "an inline recovery seals by whole-card edit and returns the new page to CardKit", %{
    event: event
  } do
    previous = ReplyPresentation.new() |> ReplyPresentation.append_answer("start")
    current = ReplyPresentation.append_answer(previous, String.duplicate("x", 13_000))
    [previous_page] = CardChain.pages(previous)

    first_card =
      CardChain.card_record(
        0,
        "card-inline-page",
        "card-inline-page-uuid",
        previous_page,
        "open",
        ["state", "answer"]
      )
      |> Map.put("message_id", "message-inline-page")
      |> Map.put("transport", "inline_message")

    checkpoint =
      %{
        "schema_version" => 1,
        "adapter" => "lark",
        "presentation" => ReplyPresentation.checkpoint(previous),
        "subject_uid" => event.agent_uid,
        "conversation_id" => Ecto.UUID.generate()
      }
      |> CardChain.initialize(first_card)

    assert {:ok, stored} =
             PreviewStates.put_checkpoint(event.id, checkpoint)

    parent = self()

    request_fun = fn
      _client, :patch, "im/v1/messages/:message_id", opts ->
        send(parent, {:inline_page_sealed, opts})
        {:ok, %{"data" => %{}}}

      _client, :post, "cardkit/v1/cards", opts ->
        send(parent, {:next_page_created, opts})
        {:ok, %{"data" => %{"card_id" => "card-next-page"}}}

      _client, :post, "im/v1/messages", opts ->
        send(parent, {:next_page_sent, opts})
        {:ok, %{"data" => %{"message_id" => "message-next-page"}}}
    end

    assert {:ok, result} =
             CardKit.update(
               %Request{
                 signal: stored,
                 presentation: current,
                 previous_presentation: previous,
                 checkpoint: checkpoint,
                 mode: :working
               },
               client: :recording_client,
               request_fun: request_fun
             )

    assert_receive {:inline_page_sealed, seal_opts}
    sealed_card = Ankole.JSON.decode!(seal_opts[:body][:content])
    assert sealed_card["config"]["streaming_mode"] == false
    assert_receive {:next_page_created, _opts}
    assert_receive {:next_page_sent, _opts}

    [sealed, active] = result.reply_preview_checkpoint["cards"]
    assert sealed["state"] == "sealed"
    assert sealed["transport"] == "inline_message"
    assert active["card_id"] == "card-next-page"
    assert active["message_id"] == "message-next-page"
    assert active["state"] == "open"
    refute active["transport"]
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
      signal: event,
      presentation: terminal,
      mode: :terminal
    }

    assert {:error, {:reply_delivery, :retryable, _provider_error}} =
             CardKit.finalize(request,
               client: :recording_client,
               request_fun: request_fun
             )

    interrupted =
      event.id
      |> then(&Ankole.Conversations.Delivery.PreviewStates.get(Repo.get!(Signal, &1)).checkpoint)
      |> PreviewAdapter.adapter_checkpoint()

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

    assert result.reply_preview_checkpoint["message_id"] ==
             "message-resume-2"
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

    intent = %Intent{
      agent_uid: event.agent_uid,
      binding_name: event.reply_binding_name,
      outbound_key: "ai-reply:oversized",
      idempotency_key: "ai-reply:oversized",
      operation: :reply,
      delivery_class: :durable_ai_reply,
      ai_message_id: Ecto.UUID.generate()
    }

    assert {:ok, result} =
             CardKit.finalize(
               %Request{
                 signal: event,
                 presentation: terminal,
                 delivery: intent,
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
    assert result.created_provider_message_id == "message-page-1"

    assert length(result.reply_preview_checkpoint["cards"]) ==
             page_count

    assert result.reply_preview_checkpoint["cards"]
           |> Enum.map_join(& &1["answer_source"]) == answer
  end

  test "request bodies and checkpoints match the fixed rendering sequence", %{event: event} do
    recorder = start_supervised!({Agent, fn -> %{requests: [], card: 0, message: 0} end})

    request_fun = fn _client, method, path, opts ->
      Agent.get_and_update(recorder, fn state ->
        recorded = %{
          "method" => to_string(method),
          "path" => path,
          "path_params" => opts[:path_params],
          "body" => opts[:body]
        }

        state = %{state | requests: state.requests ++ [recorded]}

        case {method, path} do
          {:post, "cardkit/v1/cards"} ->
            index = state.card + 1
            {{:ok, %{"data" => %{"card_id" => "golden-card-#{index}"}}}, %{state | card: index}}

          {:post, path} when path in ["im/v1/messages", "im/v1/messages/:message_id/reply"] ->
            index = state.message + 1

            {{:ok, %{"data" => %{"message_id" => "golden-message-#{index}"}}},
             %{state | message: index}}

          _mutation ->
            {{:ok, %{"data" => %{}}}, state}
        end
      end)
    end

    intent = %Intent{
      agent_uid: event.agent_uid,
      binding_name: event.reply_binding_name,
      outbound_key: "ai-reply:golden",
      idempotency_key: "ai-reply:golden",
      operation: :reply,
      delivery_class: :durable_ai_reply,
      ai_message_id: "00000000-0000-7000-8000-000000000001"
    }

    initial = ReplyPresentation.new() |> ReplyPresentation.append_answer("A")
    prefix = ReplyPresentation.append_answer(initial, "B")
    rewrite = ReplyPresentation.replace_answer(prefix, "Changed")

    thought =
      ReplyPresentation.apply_event(rewrite, "reasoning.delta", %{
        "operation_id" => "reason",
        "revision" => 4,
        "text" => "Thinking"
      })

    metadata =
      rewrite
      |> ReplyPresentation.apply_event("plan.snapshot", %{
        "operation_id" => "plan",
        "revision" => 5,
        "items" => [%{"id" => "one", "content" => "Step", "status" => "in_progress"}]
      })
      |> ReplyPresentation.apply_event("interaction.request", %{
        "revision" => 7,
        "prompt" => "Choose",
        "controls" => [
          %{
            "id" => "choice",
            "type" => "button",
            "label" => "Yes",
            "interaction_id" => "golden",
            "source_signal_id" => event.id,
            "control_id" => "choice",
            "selected_option_id" => "yes",
            "option_value" => "yes",
            "revision" => 7
          }
        ]
      })

    image =
      ReplyPresentation.append_answer(rewrite, "\n![Image](https://example.test/golden.png)")

    long = ReplyPresentation.append_answer(rewrite, String.duplicate("x", 13_000))
    inline = ReplyPresentation.append_answer(long, "tail")
    terminal = ReplyPresentation.terminal(inline, "completed", inline["answer"])

    steps = [
      {:update, initial, :normal},
      {:update, prefix, :normal},
      {:update, rewrite, :normal},
      {:update, thought, :normal},
      {:update, rewrite, :expire_thought},
      {:update, metadata, :normal},
      {:update, rewrite, :stale_element},
      {:update, image, :image_ready},
      {:update, long, :normal},
      {:refresh, long, :refresh_pending},
      {:update, inline, :normal},
      {:finalize, terminal, :normal},
      {:finalize, terminal, :normal}
    ]

    {_, _, records} =
      Enum.reduce(steps, {%{}, nil, []}, fn {operation, presentation, mutation},
                                            {checkpoint, previous, records} ->
        checkpoint =
          case mutation do
            :expire_thought ->
              Map.put(checkpoint, "cleanup_at", "2000-01-01T00:00:00.000000Z")

            :stale_element ->
              checkpoint
              |> Map.update!("element_ids", &(&1 ++ ["stale_element"]))
              |> Map.update!("cards", fn cards ->
                List.update_at(
                  cards,
                  -1,
                  &Map.update!(&1, "element_ids", fn ids -> ids ++ ["stale_element"] end)
                )
              end)

            :image_ready ->
              Map.put(checkpoint, "markdown_images", %{
                "https://example.test/golden.png" => %{
                  "status" => "ready",
                  "image_key" => "golden-image",
                  "final_url" => "https://example.test/golden.png"
                }
              })

            :refresh_pending ->
              Map.put(checkpoint, "refresh_pending", true)

            :normal ->
              checkpoint
          end

        {:ok, _} = PreviewStates.put_checkpoint(event.id, checkpoint)

        {result, record} =
          golden_cardkit_step(
            event,
            operation,
            presentation,
            previous,
            checkpoint,
            intent,
            recorder,
            request_fun
          )

        assert {:ok, delivered} = result
        checkpoint = delivered.reply_preview_checkpoint

        persisted =
          Ankole.Conversations.Delivery.PreviewStates.get(Repo.get!(Signal, event.id)).checkpoint

        assert persisted["schema_version"] == 2
        assert is_integer(persisted["sequence_high_water"])

        assert persisted
               |> PreviewAdapter.adapter_checkpoint()
               |> Map.drop(["schema_version", "sequence_high_water"]) ==
                 Map.drop(checkpoint, ["schema_version", "sequence_high_water"])

        {checkpoint, presentation, records ++ [record]}
      end)

    %{signal: action_event} =
      emit_addressed_signal(
        event.agent_uid,
        event.reply_binding_name,
        group_entry(%{
          source_event_id: unique_uid("golden-actions"),
          provider_message_id: unique_uid("golden-actions-trigger"),
          explicit: true
        })
      )

    action_presentation =
      Map.update!(metadata, "actions", fn actions ->
        Enum.map(actions, &Map.put(&1, "source_signal_id", action_event.id))
      end)

    {result, action_record} =
      golden_cardkit_step(
        action_event,
        :finalize,
        action_presentation,
        nil,
        %{},
        intent,
        recorder,
        request_fun
      )

    assert {:ok, _} = result

    %{signal: overflow_event} =
      emit_addressed_signal(
        event.agent_uid,
        event.reply_binding_name,
        group_entry(%{
          source_event_id: unique_uid("golden-overflow"),
          provider_message_id: unique_uid("golden-overflow-trigger"),
          explicit: true
        })
      )

    oversized =
      ReplyPresentation.new()
      |> ReplyPresentation.append_answer("e" <> String.duplicate("́", 13_000))

    {result, rejected} =
      golden_cardkit_step(
        overflow_event,
        :update,
        oversized,
        nil,
        %{},
        intent,
        recorder,
        request_fun
      )

    assert result == {:error, :cardkit_soft_budget_exceeded}

    {result, fallback} =
      golden_cardkit_step(
        overflow_event,
        :finalize,
        ReplyPresentation.terminal(oversized, "completed", oversized["answer"]),
        nil,
        %{},
        intent,
        recorder,
        request_fun
      )

    assert {:ok, _} = result

    records =
      golden_cardkit_normalize(records ++ [action_record, rejected, fallback], [
        event,
        action_event,
        overflow_event
      ])

    assert Ankole.JSON.encode!(Enum.at(records, 13)["requests"]) =~ "interactive_container"
    assert Ankole.JSON.encode!(Enum.at(records, 6)["requests"]) =~ "stale_element"

    assert get_in(Enum.at(records, 7), ["checkpoint", "presentation", "answer"]) =~
             "https://example.test/golden.png"

    assert get_in(Enum.at(records, 7), ["checkpoint", "answer_content"]) =~ "golden-image"
    assert Enum.at(records, 12)["requests"] == []
    path = Path.expand("../../fixtures/lark_cardkit_rendering_golden.json", __DIR__)

    if System.get_env("ANKOLE_RECORD_CARDKIT_GOLDEN") == "1" do
      File.write!(path, Ankole.JSON.encode!(records))
    end

    assert records == Ankole.JSON.decode!(File.read!(path))
  end

  defp golden_cardkit_step(
         event,
         operation,
         presentation,
         previous,
         checkpoint,
         intent,
         recorder,
         request_fun
       ) do
    Agent.update(recorder, &%{&1 | requests: []})
    before = DateTime.utc_now(:microsecond)
    previous_deadline = checkpoint["stream_deadline_at"]

    result =
      apply(CardKit, operation, [
        %Request{
          signal: Repo.get!(Signal, event.id),
          presentation: presentation,
          previous_presentation: previous,
          checkpoint: checkpoint,
          mode: if(operation == :finalize, do: :terminal, else: :working),
          delivery: intent
        },
        [client: :recording_client, request_fun: request_fun]
      ])

    after_time = DateTime.utc_now(:microsecond)

    checkpoint =
      case result do
        {:ok, %{reply_preview_checkpoint: value}} ->
          value

        _ ->
          Ankole.Conversations.Delivery.PreviewStates.get(Repo.get!(Signal, event.id)).checkpoint
      end

    if is_map(checkpoint) and is_binary(checkpoint["stream_deadline_at"]) do
      {:ok, deadline, 0} = DateTime.from_iso8601(checkpoint["stream_deadline_at"])

      if operation == :refresh do
        assert checkpoint["stream_deadline_at"] == previous_deadline
      else
        assert DateTime.compare(deadline, DateTime.add(before, 540, :second)) != :lt
        assert DateTime.compare(deadline, DateTime.add(after_time, 540, :second)) != :gt
      end

      if is_binary(checkpoint["cleanup_at"]),
        do: assert(checkpoint["cleanup_at"] == checkpoint["stream_deadline_at"])
    end

    record = %{
      "operation" => to_string(operation),
      "requests" => Agent.get(recorder, & &1.requests),
      "checkpoint" => checkpoint,
      "persisted_checkpoint" =>
        Ankole.Conversations.Delivery.PreviewStates.get(Repo.get!(Signal, event.id)).checkpoint,
      "result" =>
        case result do
          {:ok, _} -> "ok"
          {:error, reason} -> inspect(reason)
        end
    }

    {result, record}
  end

  defp golden_cardkit_normalize(value, events) when is_map(value) do
    Map.new(value, fn {key, child} ->
      key = to_string(key)

      normalized =
        cond do
          key in ["uuid", "message_uuid"] ->
            "<uuid>"

          key in ["opened_at", "closed_at", "cleanup_at", "stream_deadline_at"] and
              is_binary(child) ->
            "<timestamp>"

          true ->
            golden_cardkit_normalize(child, events)
        end

      {key, normalized}
    end)
  end

  defp golden_cardkit_normalize(value, events) when is_list(value),
    do: Enum.map(value, &golden_cardkit_normalize(&1, events))

  defp golden_cardkit_normalize(value, events) when is_binary(value) do
    Enum.reduce(Enum.with_index(events), value, fn {event, index}, value ->
      value
      |> String.replace(event.id, "<event-#{index}>")
      |> String.replace(event.agent_uid, "<agent>")
      |> String.replace(event.provider_message_id, "<trigger-#{index}>")
    end)
  end

  defp golden_cardkit_normalize(value, _events), do: value
end
