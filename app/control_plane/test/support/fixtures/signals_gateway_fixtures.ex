defmodule Ankole.SignalsGatewayFixtures do
  @moduledoc false

  # The default entries share Principal and provider identities. Their tests
  # must run serially: Sandbox retains row and advisory locks until test end.

  import ExUnit.Assertions

  alias Ankole.SignalsGateway.ActorEvent
  import Ecto.Query
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.Ingress
  alias Ankole.SignalsGateway.OutboxAdapter

  @base_time ~U[2026-07-02 01:34:05.000000Z]

  # Protocol tests construct a supervised owner directly. Reconciliation tests
  # persist bindings and enter through reconcile_once instead.
  def start_connection_owner(module, config, consumers) do
    consumers = Enum.map(consumers, &Map.put_new(&1, :tenant_id, Ankole.Repo.tenant_id!()))
    key = module.connection_key(config, consumers)

    DynamicSupervisor.start_child(
      module.__connection_lifecycle__().supervisor,
      module.owner_child_spec(key, config, consumers)
    )
  end

  @doc "Whether the running owner of `key` serves exactly this config and consumer list."
  def owner_serves?(module, key, config, consumers) do
    consumers = Enum.map(consumers, &Map.put_new(&1, :tenant_id, Ankole.Repo.tenant_id!()))
    [{_pid, value}] = Registry.lookup(module.__connection_lifecycle__().registry, key)
    value == Ankole.Plugins.ConnectionLifecycle.registry_value(config, consumers)
  end

  def base_time, do: @base_time

  def actor_commit_opts(opts) do
    Keyword.merge(
      [
        actor_event_id: Ecto.UUID.generate(),
        driver_epoch: 1
      ],
      opts
    )
  end

  def emit_addressed_actor_event(agent_uid, binding_name, entry, now \\ @base_time) do
    {:ok, result} =
      Ankole.Repo.transact(fn _repo ->
        {:ok, emit_addressed_actor_event_in_tx(agent_uid, binding_name, entry, now)}
      end)

    result
  end

  defp emit_addressed_actor_event_in_tx(agent_uid, binding_name, entry, now) do
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

    Ankole.Repo.all(
      from batch in Ankole.SignalsGateway.InboundBatch,
        where: batch.batch_state == "open" and batch.available_at <= ^now,
        order_by: [asc: batch.available_at, asc: batch.id],
        limit: ^limit
    )
    |> Enum.map(fn batch ->
      SignalsGateway.finalize_inbound_batch_by_id(batch.id, now: now)
      |> case do
        {:ok, result} -> result
        {:error, reason} -> %{status: :finalize_failed, error: reason, batch: batch}
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
    author =
      if not Map.has_key?(overrides, :author) do
        email = "signals-alice@example.com"

        uid =
          case Ankole.Repo.get_by(Ankole.Principals.HumanUser, email: email) do
            %{principal_uid: uid} ->
              uid

            nil ->
              %{principal: principal} =
                Ankole.PrincipalsFixtures.human_fixture(%{email: email, display_name: "Alice"})

              principal.uid
          end

        %{principal_uid: uid, id: "ou_alice", display_name: "Alice"}
      end

    Map.merge(
      %{
        source_event_id: "evt-1",
        signal_channel_id: "lark:chat:group-a",
        source_entry_id: "msg-1",
        provider_thread_id: "thread-1",
        channel: %{kind: :im_group, reply_mode: :entry, name: "Ops"},
        text: "hello",
        author: author,
        provider_time: @base_time
      },
      overrides
    )
  end

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
