defmodule Ankole.SignalsGateway.ActorRuntime.LLMCommandTest do
  use Ankole.SignalsGateway.ActorRuntimeCase

  setup {Ankole.SignalsGateway.ActorRuntimeCase, :use_mock_signal_provider_plugin}

  test "/llm returns usage without starting a worker when no custom profile exists" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")

    assert {:ok, %{actor_event: input}} =
             emit_entry(
               agent.uid,
               "bot",
               group_entry(%{text: "/llm", explicit: true}),
               now: @base_time
             )

    assert input.type == "command.llm_help"

    assert {:ok, %{status: :command_consumed, feedback: feedback}} =
             process_ready_events_once(now: DateTime.add(@base_time, 1, :second))

    assert feedback =~ "Usage: /llm <custom-model-profile> [message]"
    assert feedback =~ "No custom model profiles are configured"
    assert %DateTime{} = Repo.get!(ActorEvent, input.id).completed_at
    refute_receive {:actor_lane, _envelope}, 100
  end

  test "/llm help lists profiles without interrupting the active turn" do
    %{principal: agent} = agent_fixture()
    configure_custom_profile(agent.uid, "kimi", "moonshotai/kimi-k2.7-code", "high")
    binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")
    _route = register_worker!()

    assert {:ok, %{actor_event: active_input}} =
             emit_entry(
               agent.uid,
               "bot",
               group_entry(%{text: "active request", explicit: true}),
               now: @base_time
             )

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_events_once(
               now: DateTime.add(@base_time, 1, :second),
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, active_envelope}, 2_000
    active_turn = turn_start_payload!(active_envelope).turn

    assert {:ok, [_delivery]} =
             ActorRuntime.handle_turn_accepted(turn_accepted_payload(active_turn))

    assert {:ok, %{actor_event: help_event}} =
             emit_entry(
               agent.uid,
               "bot",
               group_entry(%{text: "/llm", explicit: true}),
               now: DateTime.add(@base_time, 2, :second)
             )

    assert {:ok, %{status: :command_consumed, feedback: feedback}} =
             process_ready_events_once(now: DateTime.add(@base_time, 3, :second))

    assert feedback =~ "kimi:"
    assert feedback =~ "Long-context coding"
    assert is_nil(Repo.get!(ActorEvent, active_input.id).completed_at)
    assert %DateTime{} = Repo.get!(ActorEvent, help_event.id).completed_at
    refute_receive {:actor_lane, _envelope}, 100

    assert {:ok, %{status: :noop_completed}} =
             ActorRuntime.handle_turn_noop_completed(
               turn_noop_completed_payload(active_turn, "test_complete")
             )
  end

  test "/llm profile without a body applies to one turn and the next normal message returns to primary" do
    %{principal: agent} = agent_fixture()
    configure_custom_profile(agent.uid, "kimi", "moonshotai/kimi-k2.7-code", "xhigh")
    binding_fixture(agent.uid, "bot", :ignore)
    _route = register_worker!()

    assert {:ok, %{actor_event: input}} =
             emit_entry(
               agent.uid,
               "bot",
               group_entry(%{text: "/llm kimi", explicit: true}),
               now: @base_time
             )

    assert input.type == "command.llm"
    assert get_in(input.payload, ["data", "command", "modelProfile"]) == "kimi"
    assert get_in(input.payload, ["data", "command", "argsText"]) == ""

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_events_once(
               now: DateTime.add(@base_time, 1, :second),
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, custom_envelope}, 2_000
    custom_start = turn_start_payload!(custom_envelope)
    assert custom_start.model_ref.profile == "kimi"
    assert custom_start.model_ref.model == "moonshotai/kimi-k2.7-code"

    assert custom_start.model_ref.provider_options_json ==
             Ankole.JSON.encode!(%{"reasoningEffort" => "xhigh"})

    assert {:ok, [_delivery]} =
             ActorRuntime.handle_turn_accepted(turn_accepted_payload(custom_start.turn))

    assert {:ok, %{status: :noop_completed}} =
             ActorRuntime.handle_turn_noop_completed(
               turn_noop_completed_payload(custom_start.turn, "test_complete")
             )

    assert {:ok, %{actor_event: normal_input}} =
             emit_entry(
               agent.uid,
               "bot",
               group_entry(%{
                 text: "normal request",
                 explicit: true,
                 source_event_id: "evt-normal-after-llm",
                 source_entry_id: "msg-normal-after-llm"
               }),
               now: DateTime.add(@base_time, 2, :second)
             )

    assert normal_input.type == "im.message.addressed"

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_events_once(
               now: DateTime.add(@base_time, 3, :second),
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, normal_envelope}, 2_000
    assert turn_start_payload!(normal_envelope).model_ref.profile == "primary"
  end

  test "/llm profile queues behind an active turn without steering or cancelling it" do
    %{principal: agent} = agent_fixture()
    configure_custom_profile(agent.uid, "kimi", "moonshotai/kimi-k2.7-code", "high")
    binding_fixture(agent.uid, "bot", :ignore)
    _route = register_worker!()

    assert {:ok, %{actor_event: active_input}} =
             emit_entry(
               agent.uid,
               "bot",
               group_entry(%{text: "active request", explicit: true}),
               now: @base_time
             )

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_events_once(
               now: DateTime.add(@base_time, 1, :second),
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, active_envelope}, 2_000
    active_turn = turn_start_payload!(active_envelope).turn

    assert {:ok, [_delivery]} =
             ActorRuntime.handle_turn_accepted(turn_accepted_payload(active_turn))

    assert {:ok, %{actor_event: queued_input}} =
             emit_entry(
               agent.uid,
               "bot",
               group_entry(%{text: "/llm kimi queued request", explicit: true}),
               now: DateTime.add(@base_time, 2, :second)
             )

    assert queued_input.type == "command.llm"

    assert {:ok, %{status: :idle}} =
             process_ready_events_once(now: DateTime.add(@base_time, 3, :second))

    assert is_nil(Repo.get!(ActorEvent, active_input.id).completed_at)
    assert is_nil(Repo.get!(ActorEvent, queued_input.id).completed_at)
    refute_receive {:actor_lane, _envelope}, 100

    assert {:ok, %{status: :noop_completed}} =
             ActorRuntime.handle_turn_noop_completed(
               turn_noop_completed_payload(active_turn, "test_complete")
             )

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_events_once(
               now: DateTime.add(@base_time, 4, :second),
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, queued_envelope}, 2_000
    assert turn_start_payload!(queued_envelope).model_ref.profile == "kimi"
  end

  test "/llm unknown profile returns feedback and does not start a turn" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")
    _route = register_worker!()

    assert {:ok, %{actor_event: input}} =
             emit_entry(
               agent.uid,
               "bot",
               group_entry(%{text: "/llm missing run this", explicit: true}),
               now: @base_time
             )

    assert {:ok, %{status: :command_consumed, feedback: feedback}} =
             process_ready_events_once(now: DateTime.add(@base_time, 1, :second))

    assert feedback =~ "Custom model profile missing is unavailable"
    assert %DateTime{} = Repo.get!(ActorEvent, input.id).completed_at
    refute_receive {:actor_lane, _envelope}, 100
  end

  test "/retry keeps the logical custom profile and resolves its current binding" do
    %{principal: agent} = agent_fixture()
    configure_custom_profile(agent.uid, "kimi", "moonshotai/kimi-k2.7-code", "high")
    binding_fixture(agent.uid, "bot", :ignore)
    _route = register_worker!()

    assert {:ok, %{actor_event: original}} =
             emit_entry(
               agent.uid,
               "bot",
               group_entry(%{text: "/llm kimi first run", explicit: true}),
               now: @base_time
             )

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_events_once(
               now: DateTime.add(@base_time, 1, :second),
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, first_envelope}, 2_000
    first_start = turn_start_payload!(first_envelope)
    assert first_start.model_ref.model == "moonshotai/kimi-k2.7-code"

    assert {:ok, [_delivery]} =
             ActorRuntime.handle_turn_accepted(turn_accepted_payload(first_start.turn))

    assert {:ok, %{status: :noop_completed}} =
             ActorRuntime.handle_turn_noop_completed(
               turn_noop_completed_payload(first_start.turn, "test_complete")
             )

    configure_custom_profile(agent.uid, "kimi", "moonshotai/kimi-k3-code", "max")

    assert {:ok, %{actor_event: retry_command}} =
             emit_entry(
               agent.uid,
               "bot",
               group_entry(%{
                 text: "/retry",
                 explicit: true,
                 source_event_id: "evt-retry-llm",
                 source_entry_id: "msg-retry-llm"
               }),
               now: DateTime.add(@base_time, 2, :second)
             )

    assert {:ok,
            %{
              status: :command_consumed,
              retry_actor_event: %ActorEvent{} = retried
            }} = process_ready_events_once(now: DateTime.add(@base_time, 3, :second))

    assert retry_command.type == "command.retry"
    assert retried.type == "command.llm"
    assert get_in(retried.payload, ["data", "command", "modelProfile"]) == "kimi"
    assert get_in(retried.payload, ["data", "entry", "retry_of_actor_event_id"]) == original.id

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_events_once(
               now: DateTime.add(@base_time, 4, :second),
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, retry_envelope}, 2_000
    retry_start = turn_start_payload!(retry_envelope)
    assert retry_start.model_ref.profile == "kimi"
    assert retry_start.model_ref.model == "moonshotai/kimi-k3-code"

    assert retry_start.model_ref.provider_options_json ==
             Ankole.JSON.encode!(%{"reasoningEffort" => "max"})
  end

  defp configure_custom_profile(agent_uid, name, model, effort) do
    assert {:ok, heavy} = ModelProfiles.get_model_profile(agent_uid, "heavy")

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent_uid, name, %{
               description: "Long-context coding",
               provider_id: heavy["provider_id"],
               model: model,
               provider_options: %{"reasoningEffort" => effort}
             })
  end

  defp register_worker! do
    route = unique_route()
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)
    route
  end
end
