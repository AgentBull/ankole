defmodule Ankole.Plugins.ReplyPreviewTerminalRequestTest do
  @moduledoc false
  # Pins the exact terminal `Request` that a durable AI reply row hands to each
  # provider's declared reply-preview module. That request selects the final
  # visible reply, so a changed field here is a changed provider message.
  # SignalsGateway builds the request once for every provider; the six cases
  # prove that each declared module receives the same shape.
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures
  import Ankole.SignalsGatewayFixtures

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Cache, as: AppConfigureCache
  alias Ankole.AppConfigure.Registry, as: AppConfigureRegistry
  alias Ankole.Plugins.DingTalkAdapter
  alias Ankole.Plugins.DiscordAdapter
  alias Ankole.Plugins.LarkAdapter
  alias Ankole.Plugins.SlackAdapter
  alias Ankole.Plugins.TelegramAdapter
  alias Ankole.Plugins.WeComAdapter
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.Actors
  alias Ankole.SignalsGateway.OutboxEntry
  alias Ankole.SignalsGateway.ReplyPresentation
  alias Ankole.SignalsGateway.ReplyPreviewAdapter
  alias Ankole.SignalsGateway.ReplyPreviewAdapter.Request

  @subject_uid "human-a"
  @conversation_id "conversation-a"

  setup do
    previous = Req.default_options()
    on_exit(fn -> Req.default_options(previous) end)

    # The provider call after the captured request must fail fast without a
    # network: every provider client goes through Req.
    Req.default_options(
      retry: false,
      plug: fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(400, ~s({"ok":false,"code":400,"error":"snapshot"}))
      end
    )

    AppConfigureRegistry.clear_for_test()
    AppConfigureCache.clear_for_test()
    :ok
  end

  describe "terminal reply-preview request" do
    test "slack" do
      fixture =
        provider_fixture(
          adapter: "slack",
          binding: "slack-final",
          channel: "slack:C1",
          config_key: &SlackAdapter.Config.chat_config_key/1,
          config: %{"botToken" => "xoxb-bot", "appToken" => "xapp-app"}
        )

      assert capture_terminal_request(SlackAdapter.ReplyPreview, fixture) ==
               expected_request(fixture)
    end

    test "lark" do
      fixture =
        provider_fixture(
          adapter: "lark",
          binding: "lark-final",
          channel: "lark:chat:group-a",
          config_key: &LarkAdapter.Config.chat_config_key/1,
          config: %{"appID" => "cli_a", "appSecret" => "secret"}
        )

      assert capture_terminal_request(LarkAdapter.CardKit, fixture) == expected_request(fixture)
    end

    test "dingtalk" do
      fixture =
        provider_fixture(
          adapter: "dingtalk",
          binding: "dingtalk-final",
          channel: "dingtalk:cidG",
          config_key: &DingTalkAdapter.Config.chat_config_key/1,
          config: %{"clientId" => "cli", "clientSecret" => "secret", "cardTemplateId" => "tpl-1"}
        )

      assert capture_terminal_request(DingTalkAdapter.AICard, fixture) ==
               expected_request(fixture)
    end

    test "wecom" do
      fixture =
        provider_fixture(
          adapter: "wecom",
          binding: "wecom-final",
          channel: "wecom:wr-final",
          config_key: &WeComAdapter.Config.chat_config_key/1,
          config: %{"botId" => "bot-final", "secret" => "secret"}
        )

      assert capture_terminal_request(WeComAdapter.AIStream, fixture) ==
               expected_request(fixture)
    end

    test "discord" do
      fixture =
        provider_fixture(
          adapter: "discord",
          binding: "discord-final",
          channel: "discord:77:channel:501",
          config_key: &DiscordAdapter.Config.binding_config_key/2,
          config: %{"botToken" => "discord-final-token"}
        )

      assert capture_terminal_request(DiscordAdapter.ReplyPreview, fixture) ==
               expected_request(fixture)
    end

    test "telegram" do
      fixture =
        provider_fixture(
          adapter: "telegram",
          binding: "telegram-final",
          channel: "telegram:909:chat:501",
          config_key: &TelegramAdapter.Config.binding_config_key/2,
          config: %{"botToken" => "909:final-token"}
        )

      assert capture_terminal_request(TelegramAdapter.ReplyPreview, fixture) ==
               expected_request(fixture)
    end
  end

  defp expected_request(fixture) do
    checkpoint = ReplyPreviewAdapter.adapter_checkpoint(fixture.checkpoint)

    %Request{
      actor_event: fixture.event,
      presentation: fixture.presentation,
      previous_presentation: checkpoint["presentation"],
      checkpoint: checkpoint,
      subject_uid: @subject_uid,
      conversation_id: @conversation_id,
      outbox: fixture.outbox,
      config: fixture.config,
      mode: :terminal
    }
  end

  # Runs the terminal route in a task and records the request that reaches the
  # preview module. Tracing observes the real call instead of replacing the
  # module.
  defp capture_terminal_request(preview_module, fixture) do
    {:ok, adapter} = ReplyPreviewAdapter.from_module(preview_module)
    outbox = fixture.outbox

    task =
      Task.async(fn ->
        receive(do: (:go -> ReplyPreviewAdapter.finalize_outbox(adapter, outbox)))
      end)

    pid = task.pid

    :erlang.trace(pid, true, [:call])
    :erlang.trace_pattern({preview_module, :finalize, 1}, true, [:global])
    on_exit(fn -> :erlang.trace_pattern({preview_module, :finalize, 1}, false, [:global]) end)

    send(pid, :go)
    _result = Task.await(task, 10_000)

    assert_receive {:trace, ^pid, :call, {^preview_module, :finalize, [%Request{} = request]}}
    request
  end

  defp provider_fixture(opts) do
    adapter = Keyword.fetch!(opts, :adapter)
    binding_name = Keyword.fetch!(opts, :binding)
    channel = Keyword.fetch!(opts, :channel)
    %{principal: agent} = agent_fixture()

    config_key =
      case Keyword.fetch!(opts, :config_key) do
        key_fun when is_function(key_fun, 1) ->
          key_fun.("#{adapter}-final-#{System.unique_integer([:positive])}")

        key_fun when is_function(key_fun, 2) ->
          key_fun.(agent.uid, binding_name)
      end

    {:ok, _config} = AppConfigure.put_global_by_key(config_key, Keyword.fetch!(opts, :config))
    {:ok, stored_config} = AppConfigure.get_by_key(config_key)

    {:ok, _binding} =
      SignalsGateway.upsert_binding(%{
        agent_uid: agent.uid,
        name: binding_name,
        adapter: adapter,
        config_ref: "app-config://#{config_key}",
        filters: %{},
        unaddressed_group_message_policy: :ignore,
        unmatched_sender_policy: :create_standalone
      })

    %{actor_event: event} =
      emit_addressed_actor_event(
        agent.uid,
        binding_name,
        group_entry(%{
          source_event_id: unique_uid("#{adapter}-event"),
          source_entry_id: unique_uid("#{adapter}-trigger"),
          signal_channel_id: channel,
          explicit: true
        })
      )

    working =
      ReplyPresentation.new(state: "working") |> ReplyPresentation.replace_answer("draft")

    {:ok, _event} =
      Actors.put_reply_preview_checkpoint(event.id, %{
        "schema_version" => 1,
        "adapter" => adapter,
        "subject_uid" => @subject_uid,
        "conversation_id" => @conversation_id,
        "presentation" => ReplyPresentation.checkpoint(working),
        "streaming_state" => "open"
      })

    event = Repo.get!(ActorEvent, event.id)

    presentation =
      ReplyPresentation.new() |> ReplyPresentation.terminal("completed", "final answer")

    outbox = %OutboxEntry{
      agent_uid: agent.uid,
      binding_name: binding_name,
      outbound_key: "ai-reply:#{event.id}",
      delivery_class: :durable_ai_reply,
      operation: :reply,
      status: :sending,
      signal_channel_id: channel,
      provider_thread_id: event.provider_thread_id,
      reply_to_source_entry_id: event.source_entry_id,
      source_actor_event_id: event.id,
      payload: %{
        "reply_presentation" => presentation,
        "metadata" => %{"source" => "ai_reply"}
      },
      fallback_visible_text: "final answer",
      idempotency_key: "ai-reply:#{event.id}",
      attempt_count: 1
    }

    %{
      agent: agent,
      event: event,
      checkpoint: event.reply_preview_checkpoint,
      presentation: presentation,
      outbox: outbox,
      config: stored_config
    }
  end
end
