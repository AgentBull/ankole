defmodule Ankole.SignalsGatewayFixtures do
  @moduledoc false

  import ExUnit.Assertions

  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.RuntimeEvents
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.Ingress
  alias Ankole.SignalsGateway.OutboxAdapter

  @base_time ~U[2026-07-02 01:34:05.000000Z]

  def base_time, do: @base_time

  def actor_commit_opts(opts) do
    Keyword.merge(
      [
        actor_event_id: Ecto.UUID.generate(),
        activation_uid:
          "test-activation-" <> Integer.to_string(System.unique_integer([:positive])),
        actor_epoch: 1,
        revision: 0
      ],
      opts
    )
  end

  def emit_addressed_actor_event(agent_uid, binding_name, entry, now \\ @base_time) do
    assert {:ok, %{status: :accepted, inbound_batch: batch}} =
             Ingress.emit_entry(agent_uid, binding_name, entry, now: now)

    assert {:ok, results} =
             finalize_due_inbound_batch_events(now: batch.available_at)

    actor_event =
      Enum.find_value(results, fn
        %{actor_event: %ActorEvent{} = input} -> input
        _result -> nil
      end)

    assert %ActorEvent{} = actor_event
    %{inbound_batch: batch, actor_event: actor_event}
  end

  def finalize_due_inbound_batch_events(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))
    limit = Keyword.get(opts, :limit, 500)

    SignalsGateway.runtime_event_snapshot()
    |> Enum.filter(fn {channel, payload} ->
      channel == RuntimeEvents.inbound_batch_due_channel() and runtime_event_due?(payload, now)
    end)
    |> Enum.sort_by(fn {_channel, payload} ->
      {Map.fetch!(payload, "due_at"), Map.fetch!(payload, "batch_id")}
    end)
    |> Enum.take(limit)
    |> Enum.map(fn {_channel, payload} ->
      SignalsGateway.finalize_inbound_batch_by_id(
        Map.fetch!(payload, "batch_id"),
        Map.fetch!(payload, "batch_revision"),
        now: now
      )
      |> case do
        {:ok, result} -> result
        {:error, reason} -> %{status: :finalize_failed, error: reason, payload: payload}
      end
    end)
    |> then(&{:ok, &1})
  end

  # Tests that exercise message mechanics default to :create_standalone so an
  # unseeded sender still flows; identity-admission tests pass :manual_review.
  def binding_fixture(agent_uid, name, policy, opts \\ []) do
    {:ok, binding} =
      SignalsGateway.upsert_binding(%{
        agent_uid: agent_uid,
        name: name,
        adapter: Keyword.get(opts, :adapter, "lark"),
        config_ref: "app-config://#{name}",
        filters: Keyword.get(opts, :filters, %{}),
        unaddressed_group_message_policy: policy,
        unmatched_sender_policy: Keyword.get(opts, :unmatched_sender_policy, :create_standalone),
        unavailable_reason: Keyword.get(opts, :unavailable_reason)
      })

    binding
  end

  def group_entry(overrides \\ %{}) do
    Map.merge(
      %{
        source_event_id: "evt-1",
        signal_channel_id: "lark:chat:group-a",
        source_entry_id: "msg-1",
        provider_thread_id: "thread-1",
        channel: %{kind: :im_group, reply_mode: :entry, name: "Ops"},
        text: "hello",
        author: %{principal_uid: "alice", id: "ou_alice", display_name: "Alice"},
        provider_time: @base_time
      },
      overrides
    )
  end

  defp runtime_event_due?(%{"due_at" => nil}, _now), do: true

  defp runtime_event_due?(%{"due_at" => due_at}, now) when is_binary(due_at) do
    case DateTime.from_iso8601(due_at) do
      {:ok, due_at, _offset} -> DateTime.compare(due_at, now) != :gt
      _invalid -> false
    end
  end

  defp runtime_event_due?(_payload, _now), do: true

  def lifecycle_entry(overrides) do
    Map.merge(
      %{
        source_event_id: "delete-1",
        signal_channel_id: "lark:chat:group-a",
        source_entry_id: "msg-1",
        provider_thread_id: "thread-1",
        channel: %{kind: :im_group, reply_mode: :entry, name: "Ops"}
      },
      overrides
    )
  end

  def webhook_entry(overrides) do
    Map.merge(
      %{
        source_event_id: "hook-event-1",
        signal_channel_id: "webhook:incident-1",
        source_entry_id: "hook-1",
        channel: %{kind: :webhook_endpoint, reply_mode: :none, name: "Incident hook"},
        text: "incident opened",
        actor_event_type: "webhook.received",
        provider_time: @base_time
      },
      overrides
    )
  end

  def outbox_adapter(capabilities, send_fun, reconcile_fun \\ nil) do
    %OutboxAdapter{
      capabilities: MapSet.new(capabilities),
      send_fun: send_fun,
      reconcile_fun: reconcile_fun
    }
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
        outbox_adapter(capabilities, fn _outbox -> {:ok, adapter_result} end),
        now: @base_time
      )
    end
  end
end
