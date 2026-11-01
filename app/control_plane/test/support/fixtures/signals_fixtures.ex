defmodule Ankole.SignalsFixtures do
  @moduledoc false

  def delivery_fixture!(attrs) do
    alias Ankole.Conversations.Delivery.Intent

    attrs =
      Map.put_new_lazy(attrs, :binding_id, fn ->
        case Ankole.Signals.get_agent_binding!(attrs.agent_uid, attrs.binding_name) do
          nil -> nil
          binding -> binding.id
        end
      end)

    {status, attrs} = Map.pop(attrs, :status, :pending)
    {attempts, attrs} = Map.pop(attrs, :attempt_count, 0)
    {started_at, attrs} = Map.pop(attrs, :platform_send_started_at)
    {timestamps, attrs} = Map.split(attrs, [:inserted_at, :updated_at])
    {provider_id, attrs} = Map.pop(attrs, :created_provider_message_id)

    {:ok, intent} =
      Ankole.Repo.transact(fn ->
        with {:ok, intent} <- Ankole.Ash.create(Intent, :commit, attrs) do
          intent =
            if attempts == 1 or status in [:sent, :failed] or not is_nil(started_at) do
              {:ok, sending} =
                Ankole.Ash.update(intent, :start_attempt, %{
                  platform_send_started_at: started_at || DateTime.utc_now(:microsecond)
                })

              sending
            else
              0 = attempts
              intent
            end

          case status do
            :pending ->
              {:ok, intent}

            :sent ->
              Ankole.Ash.update(intent, :succeed, %{created_provider_message_id: provider_id})

            :failed ->
              Ankole.Ash.update(intent, :fail, %{})
          end
        end
      end)

    # Historical timing fixtures retain their explicit clock without exposing
    # timestamp mutation in a production action.
    if map_size(timestamps) == 0 do
      intent
    else
      intent
      |> AshPostgres.DataLayer.to_ecto()
      |> Ecto.Changeset.change(timestamps)
      |> Ankole.Repo.update!()
    end
  end

  # The default entries share Principal and provider identities. Their tests
  # must run serially: Sandbox retains row and advisory locks until test end.

  import ExUnit.Assertions

  alias Ankole.Signals.Signal
  import Ecto.Query

  alias Ankole.Conversations.Observe
  alias Ankole.Conversations.Delivery.Adapter

  @base_time ~U[2026-07-02 01:34:05.000000Z]

  def commit_delivery(attrs) do
    Ankole.Repo.transact(fn -> Ankole.Conversations.Delivery.commit_in_tx(attrs) end)
  end

  def owner_status(server) do
    {:status, _pid, _module, [_dictionary, _status, _parent, _debug, formatted]} =
      :sys.get_status(server)

    {_label, state} =
      formatted |> Keyword.get_values(:data) |> List.flatten() |> List.keyfind(~c"State", 0)

    state
  end

  # Protocol tests construct a supervised owner directly. Reconciliation tests
  # persist bindings and enter through reconcile_once instead.
  def start_connection_owner(module, config, consumers) do
    consumers = Enum.map(consumers, &Map.put_new(&1, :tenant_id, Ankole.Repo.tenant_id!()))
    key = module.connection_key(config, consumers)

    case DynamicSupervisor.start_child(
           module.__connection_lifecycle__().supervisor,
           module.owner_child_spec(key, config, consumers)
         ) do
      {:ok, _pid} = result ->
        ExUnit.Callbacks.on_exit(fn ->
          if Process.whereis(module.__connection_lifecycle__().registry), do: module.stop(key)
        end)

        result

      error ->
        error
    end
  end

  @doc "Whether the running owner of `key` serves exactly this config and consumer list."
  def owner_serves?(module, key, config, consumers) do
    consumers = Enum.map(consumers, &Map.put_new(&1, :tenant_id, Ankole.Repo.tenant_id!()))
    [{_pid, value}] = Registry.lookup(module.__connection_lifecycle__().registry, key)
    value == Ankole.Plugins.ConnectionLifecycle.registry_value(config, consumers)
  end

  def base_time, do: @base_time

  def external_session_signal_fixture(agent_uid, opts \\ []) do
    unique = System.unique_integer([:positive])
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))
    binding_name = Keyword.get(opts, :binding_name, "test-external")
    binding = binding_fixture(agent_uid, binding_name, :record_only, adapter: "mock")
    provider_message_id = "test-source-#{unique}"

    {:ok, signal} =
      Ankole.Repo.transact(fn ->
        with {:ok, conversation} <-
               Ankole.Conversations.External.observe_conversation_in_tx(
                 binding,
                 %{
                   provider_conversation_id: "mock:test-source-#{unique}",
                   external_kind: :im_group,
                   reply_mode: :entry
                 },
                 now
               ),
             {:ok, observation} <-
               Ankole.Conversations.External.observe_in_tx(
                 conversation.id,
                 %{
                   provider_message_id: provider_message_id,
                   provider_thread_id: "test-thread",
                   text: "Test stimulus",
                   author: %{"id" => "test-author"},
                   provider_time: now
                 },
                 now
               ) do
          Ankole.Signals.accept_in_tx(%{
            producer: :kernel,
            source: Keyword.get(opts, :source, "test://external-session"),
            id: "test-event-#{unique}",
            type: Keyword.get(opts, :type, "test.source"),
            time: now,
            data: %{"text" => observation.message.text, "message_id" => observation.message.id},
            message_id: observation.message.id,
            target: %{agent_uid: agent_uid, conversation_id: conversation.id},
            authorization: Ankole.Principals.WorkAccess.service(),
            sender: agent_uid,
            reply_route: %{
              binding_name: binding.name,
              conversation_id: conversation.id,
              provider_thread_id: observation.external_ref.provider_thread_id,
              provider_message_id: provider_message_id
            }
          })
        end
      end)

    signal
  end

  def actor_commit_opts(opts) do
    Keyword.merge(
      [
        signal_id: Ecto.UUID.generate(),
        driver_epoch: 1
      ],
      opts
    )
  end

  # Observation and batch finalization are top-level actions; each owns its
  # transaction.
  def emit_addressed_signal(agent_uid, binding_name, entry, now \\ @base_time) do
    assert {:ok, %{status: :accepted, inbound_batch: batch} = observed} =
             Observe.emit_entry(
               Ankole.Signals.get_agent_binding!(agent_uid, binding_name).id,
               entry,
               now: now
             )

    assert {:ok, results} =
             finalize_due_inbound_batch_events(now: batch.available_at)

    signal =
      Enum.find_value(results, fn
        %{signal: %Signal{} = input} -> input
        _result -> nil
      end)

    assert %Signal{} = signal
    Map.put(observed, :signal, signal)
  end

  def finalize_due_inbound_batch_events(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))
    limit = Keyword.get(opts, :limit, 500)

    Ankole.Repo.all(
      from(batch in Ankole.Conversations.InboundBatch,
        where: batch.batch_state == :open and batch.available_at <= ^now,
        order_by: [asc: batch.available_at, asc: batch.id],
        limit: ^limit
      )
    )
    |> Enum.map(fn batch ->
      Ankole.Conversations.InboundBatches.finalize_inbound_batch_by_id(batch.id, now: now)
      |> case do
        {:ok, result} -> result
        {:error, reason} -> %{status: :finalize_failed, error: reason, batch: batch}
      end
    end)
    |> then(&{:ok, &1})
  end

  # Seeds persisted state without configuration validation or post-save wakeups.
  # Use the production put/update operations for the behavior under test.
  def raw_binding_fixture(attrs) when is_map(attrs) do
    Ankole.Repo.transact(fn ->
      Ankole.Ash.create(Ankole.Signals.Binding, :put, attrs)
    end)
  end

  def raw_binding_fixture(%Ankole.Signals.Binding{} = binding, attrs) do
    fields = Ash.Resource.Info.action(Ankole.Signals.Binding, :put).accept
    binding |> Map.take(fields) |> Map.merge(attrs) |> raw_binding_fixture()
  end

  # Tests that exercise message mechanics default to :create_standalone so an
  # unseeded sender still flows; identity-admission tests pass :manual_review.
  def binding_fixture(agent_uid, name, policy, opts \\ []) do
    previous = Ankole.Signals.get_agent_binding!(agent_uid, name)

    attrs = %{
      agent_uid: agent_uid,
      name: name,
      adapter: Keyword.get(opts, :adapter, "lark"),
      config_ref: "app-config://#{name}",
      filters: Keyword.get(opts, :filters, %{}),
      unaddressed_group_message_policy: policy,
      unmatched_sender_policy: Keyword.get(opts, :unmatched_sender_policy, :create_standalone),
      unavailable_reason: Keyword.get(opts, :unavailable_reason)
    }

    {:ok, binding} =
      if previous, do: raw_binding_fixture(previous, attrs), else: raw_binding_fixture(attrs)

    binding
  end

  def provider_author_fixture(principal_uid, external_id, attrs \\ %{}) do
    provider = Map.get(attrs, :provider, "signals-fixture")

    {:ok, _} =
      Ankole.Repo.transact(fn ->
        Ankole.Principals.upsert_platform_subject_human_in_tx(%{
          uid: principal_uid,
          provider: provider,
          external_id: external_id
        })
      end)

    Map.merge(%{provider: provider, platform_subject: external_id, id: external_id}, attrs)
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

        provider_author_fixture(uid, "ou_alice", %{display_name: "Alice"})
      end

    Map.merge(
      %{
        source_event_id: "evt-1",
        provider_conversation_id: "lark:chat:group-a",
        provider_message_id: "msg-1",
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
        provider_conversation_id: "lark:chat:group-a",
        provider_message_id: "msg-1",
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
        provider_conversation_id: "webhook:incident-1",
        provider_message_id: "hook-1",
        channel: %{kind: :webhook_endpoint, reply_mode: :none, name: "Incident hook"},
        text: "incident opened",
        signal_type: "webhook.received",
        provider_time: @base_time
      },
      overrides
    )
  end

  def delivery_adapter(capabilities, deliver_fun, reconcile_fun \\ nil) do
    %Adapter{
      capabilities: MapSet.new(capabilities),
      deliver_fun: deliver_fun,
      reconcile_fun: reconcile_fun
    }
  end

  def commit_and_dispatch(agent_uid, binding_name, attrs, capabilities, adapter_result) do
    attrs =
      attrs
      |> Map.put(:agent_uid, agent_uid)
      |> Map.put(:binding_name, binding_name)

    with {:ok, _intent} <- Ankole.SignalsFixtures.commit_delivery(attrs) do
      Ankole.Conversations.Delivery.dispatch(
        agent_uid,
        binding_name,
        attrs.outbound_key,
        delivery_adapter(capabilities, fn _intent -> {:ok, adapter_result} end),
        now: @base_time
      )
    end
  end
end
