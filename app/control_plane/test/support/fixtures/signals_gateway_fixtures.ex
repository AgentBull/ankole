defmodule Ankole.SignalsGatewayFixtures do
  @moduledoc false

  import ExUnit.Assertions

  alias Ankole.Actors.ActorInput
  alias Ankole.SignalsGateway

  @base_time ~U[2026-06-23 08:00:00.000000Z]

  defmodule ModuleOutboxAdapter do
    @moduledoc false

    @behaviour Ankole.SignalsGateway.OutboxAdapter

    def capabilities, do: [:post_entry]

    def send(_outbox), do: {:ok, %{provider_entry_id: "module-adapter-msg"}}
  end

  def base_time, do: @base_time

  def actor_commit_opts(opts) do
    Keyword.merge(
      [
        llm_turn_id: Ecto.UUID.generate(),
        activation_uid:
          "test-activation-" <> Integer.to_string(System.unique_integer([:positive])),
        actor_epoch: 1,
        revision: 0
      ],
      opts
    )
  end

  def emit_addressed_actor_input(agent_uid, binding_name, entry, now \\ @base_time) do
    assert {:ok, %{status: :accepted, inbound_batch: batch}} =
             SignalsGateway.emit_entry(agent_uid, binding_name, entry, now: now)

    assert {:ok, results} =
             SignalsGateway.finalize_due_inbound_batches(
               now: DateTime.add(now, 600, :millisecond)
             )

    actor_input =
      Enum.find_value(results, fn
        %{actor_input: %ActorInput{} = input} -> input
        _result -> nil
      end)

    assert %ActorInput{} = actor_input
    %{inbound_batch: batch, actor_input: actor_input}
  end

  def binding_fixture(agent_uid, name, policy, opts \\ []) do
    {:ok, binding} =
      SignalsGateway.upsert_binding(%{
        agent_uid: agent_uid,
        name: name,
        adapter: Keyword.get(opts, :adapter, "lark"),
        config_ref: "app-config://#{name}",
        filters: Keyword.get(opts, :filters, %{}),
        unaddressed_group_message_policy: policy,
        unavailable_reason: Keyword.get(opts, :unavailable_reason)
      })

    binding
  end

  def group_entry(overrides \\ %{}) do
    Map.merge(
      %{
        ingress_event_id: "evt-1",
        signal_channel_id: "lark:chat:group-a",
        provider_entry_id: "msg-1",
        provider_thread_id: "thread-1",
        channel: %{kind: :im_group, reply_mode: :entry, name: "Ops"},
        text: "hello",
        author: %{principal_uid: "alice", id: "ou_alice", display_name: "Alice"},
        provider_time: @base_time
      },
      overrides
    )
  end

  def lifecycle_entry(overrides) do
    Map.merge(
      %{
        ingress_event_id: "delete-1",
        signal_channel_id: "lark:chat:group-a",
        provider_entry_id: "msg-1",
        provider_thread_id: "thread-1",
        channel: %{kind: :im_group, reply_mode: :entry, name: "Ops"}
      },
      overrides
    )
  end

  def webhook_entry(overrides) do
    Map.merge(
      %{
        ingress_event_id: "hook-event-1",
        signal_channel_id: "webhook:incident-1",
        provider_entry_id: "hook-1",
        channel: %{kind: :webhook_endpoint, reply_mode: :none, name: "Incident hook"},
        text: "incident opened",
        actor_input_type: "webhook.received",
        provider_time: @base_time
      },
      overrides
    )
  end

  def commit_and_dispatch(agent_uid, binding_name, attrs, capabilities, adapter_result) do
    attrs =
      attrs
      |> Map.put(:agent_uid, agent_uid)
      |> Map.put(:binding_name, binding_name)

    with {:ok, _outbox} <- SignalsGateway.commit_outbox(attrs) do
      SignalsGateway.dispatch_outbox(
        agent_uid,
        binding_name,
        attrs.outbound_key,
        %{capabilities: capabilities, send: fn _outbox -> {:ok, adapter_result} end},
        now: @base_time
      )
    end
  end
end
