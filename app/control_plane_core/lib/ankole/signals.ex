defmodule Ankole.Signals do
  @moduledoc """
  Accepts durable stimuli, resolves their target, and records a committed wakeup.

  This module is the Signals domain. Its defines are the interface for other
  domains. A generic action owns its transaction; the `*_in_tx` functions are
  steps that the generic action of another domain calls in its own transaction.
  """
  use Ankole.Ash.Domain

  require Ash.Query
  require Ash.Sort

  alias Ankole.Signals.{Intake, Signal}

  resources do
    resource Ankole.Signals.Signal do
      define(:get_signal, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_signals, action: :read)
      define(:refund_attempt_signal, action: :refund_attempt)
      define(:revise_input_signal, action: :revise_input)
      define(:update_metadata_signal, action: :update_metadata)
      define(:reauthorize_signal, action: :reauthorize)
      define(:remove_signal, action: :remove)
      define(:intake, action: :intake, args: [:attrs])
      define(:intake_all, action: :intake_all, args: [:attrs_list])
    end

    resource Ankole.Signals.Binding do
      define(:get_binding, action: :read, get_by: [:agent_uid, :name], not_found_error?: false)
      define(:list_bindings, action: :read)
      define(:assign_binding, action: :assign, args: [:assignment])
      define(:reassign_binding, action: :reassign, args: [:assignment])
      define(:put_cloud_binding, action: :put_cloud, args: [:binding])
      define(:move_cloud_binding, action: :move_cloud, args: [:source, :current_config, :binding])
      define(:disable_binding, action: :disable_by_name, args: [:agent_uid, :name])
    end

    resource Ankole.Signals.WebhookEndpoint do
      define(:get_webhook_endpoint, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_webhook_endpoints, action: :read)
      define(:create_webhook_endpoint, action: :create_endpoint, args: [:attrs, :token])

      define(:cancel_webhook_endpoint,
        action: :cancel_endpoint,
        args: [:agent_uid, :session_id, :endpoint_id, :now]
      )

      define(:receive_webhook, action: :receive, args: [:token, :format, :input, :now])
    end
  end

  @doc "Locks a Signal row inside the caller-owned transaction."
  def lock_signal_in_tx(_repo, signal_id) do
    Signal
    |> Ash.Query.filter(id == ^signal_id)
    |> Ash.Query.lock(:for_update)
    |> Ankole.Ash.read_one!(lock_identity: {"signals", signal_id})
  end

  @doc "Locks a Signal of one Session queue inside the caller-owned transaction."
  def lock_session_signal_in_tx(_repo, %{agent_uid: uid, session_id: session}, signal_id) do
    Signal
    |> Ash.Query.filter(id == ^signal_id and agent_uid == ^uid and session_id == ^session)
    |> Ash.Query.lock(:for_update)
    |> Ankole.Ash.read_one!(lock_identity: {"signals", signal_id})
  end

  @doc "Reads a Binding with a share lock inside the caller-owned transaction."
  def share_binding_in_tx(_repo, agent_uid, binding_name) do
    Ankole.Signals.Binding
    |> Ash.Query.filter(agent_uid == ^agent_uid and name == ^binding_name)
    |> Ash.Query.lock("FOR SHARE")
    |> Ankole.Ash.read_one!()
  end

  @doc """
  Locks the Signals that a keyword filter selects inside the caller-owned
  transaction.

  The rows come in queue order. `sort:` gives another order and `limit:` keeps
  only the first rows.
  """
  def lock_signals_in_tx(_repo, filter, opts \\ []) do
    Signal
    |> Ash.Query.do_filter(filter)
    |> Ash.Query.sort(Keyword.get(opts, :sort, queue_sequence: :asc))
    |> then(&if(limit = opts[:limit], do: Ash.Query.limit(&1, limit), else: &1))
    |> Ash.Query.lock(:for_update)
    |> Ankole.Ash.read!(lock_identity: {:rows, "signals", :id})
  end

  @doc """
  Reads the open input of one Session queue in queue order.

  Queued follow-up input of a native conversation waits while the
  conversation pauses its queue. The options are `due_at:` (only the input
  that is due at this time), `started?: true` (only admitted input), and
  `limit:`.
  """
  def session_queue(agent_uid, session_id, opts \\ []) do
    agent_uid
    |> open_query(session_id)
    |> due_by(Keyword.get(opts, :due_at))
    |> started(Keyword.get(opts, :started?, false))
    |> Ash.Query.sort(queue_sequence: :asc)
    |> then(&if(limit = opts[:limit], do: Ash.Query.limit(&1, limit), else: &1))
    |> Ankole.Ash.read!()
  end

  @doc "Gives the runnable or admitted input that the public Session status reports."
  def session_status_signal(agent_uid, session_id, now) do
    agent_uid
    |> open_query(session_id)
    |> Ash.Query.sort([
      {Ash.Sort.expr_sort(
         fragment(
           "CASE WHEN ? > ? THEN 2 WHEN ? IS NULL THEN 1 ELSE 0 END",
           available_at,
           ^now,
           last_attempt_at
         ),
         :integer
       ), :asc},
      {:available_at, :asc},
      {:queue_sequence, :asc}
    ])
    |> Ash.Query.limit(1)
    |> Ankole.Ash.read_one!()
  end

  defp open_query(agent_uid, session_id) do
    Signal
    |> Ash.Query.filter(
      agent_uid == ^agent_uid and session_id == ^session_id and status in [:queued, :running]
    )
    |> Ash.Query.filter(
      not is_nil(last_attempt_at) or type != "conversation.message.addressed" or
        fragment("COALESCE(?->>'delivery_mode', 'steer')", data) != "queue" or
        not exists(
          native_conversation,
          fragment("COALESCE(?->>'queue_paused', 'false')", metadata) == "true"
        )
    )
  end

  defp due_by(query, nil), do: query
  defp due_by(query, now), do: Ash.Query.filter(query, available_at <= ^now)

  defp started(query, false), do: query
  defp started(query, true), do: Ash.Query.filter(query, not is_nil(last_attempt_at))

  @doc "Gives the Sessions of every tenant that have due open input."
  def due_sessions_across_tenants(now) do
    Ankole.Repo.across_tenants(fn ->
      Signal
      |> Ash.Query.for_read(:work_across_tenants, %{}, authorize?: false)
      |> Ash.Query.filter(status in [:queued, :running] and available_at <= ^now)
      |> Ash.Query.distinct([:agent_uid, :session_id])
      |> Ash.Query.select([:agent_uid, :session_id, :tenant_id])
      |> Ash.read!(authorize?: false)
      |> Enum.map(&Map.take(&1, [:agent_uid, :session_id, :tenant_id]))
    end)
  end

  @doc """
  Counts, in every tenant, the admitted open Signals of a Human whose work
  access version is older than `version`. Access cleanup lets these attempts
  finish.
  """
  def count_admitted_attempts_for_human(uid, version) do
    Ankole.Repo.across_tenants(fn ->
      Signal
      |> Ash.Query.for_read(:work_across_tenants, %{}, authorize?: false)
      |> Ash.Query.filter(
        human_uid == ^uid and human_access_version < ^version and
          status in [:queued, :running] and not is_nil(last_attempt_at)
      )
      |> Ash.count!(authorize?: false)
    end)
  end

  @transitions [
    :admit,
    :retry_triage,
    :start_attempt,
    :defer,
    :complete,
    :dead_letter,
    :refund_attempt
  ]

  @doc """
  Moves a locked Signal through one queue action inside the caller-owned
  transaction. The Signal state machine accepts or refuses the move.
  """
  def transition_in_tx(_repo, %Signal{} = signal, action, input \\ %{})
      when action in @transitions,
      do: Ankole.Ash.update(signal, action, input)

  @doc "Gives the Signals back their failure budget and makes them due at `available_at`."
  def reset_attempts_in_tx(_repo, ids, available_at) do
    Signal
    |> Ash.Query.filter(id in ^ids)
    |> Ankole.Ash.update_where(:reset_attempts, %{available_at: available_at})
  end

  @doc "Dead-letters the unstarted Signals of a Human whose work access ended."
  def stop_human_work_in_tx(_repo, uid, version, now) do
    {:ok, revoked} =
      Signal
      |> Ash.Query.filter(
        human_uid == ^uid and human_access_version < ^version and status == :queued and
          is_nil(last_attempt_at)
      )
      |> Ankole.Ash.update_where(:revoke_unstarted, %{
        dead_letter_at: now,
        dead_letter_reason: %{"reason" => "human_access_revoked"}
      })

    {length(revoked), nil}
  end

  @doc "Locks an already resolved execution target before its public Conversation row."
  def lock_target_in_tx(repo, %{agent_uid: uid, session_id: key}),
    do: Ankole.Sessions.Queue.lock_session_in_tx(repo, uid, key)

  @doc """
  Returns completed Signals for a provider entry inside a caller-owned transaction.
  """
  @spec signals_for_entry_in_tx(
          module(),
          String.t(),
          String.t(),
          String.t(),
          String.t()
        ) :: [Signal.t()]
  def signals_for_entry_in_tx(
        _repo,
        agent_uid,
        binding_name,
        conversation_id,
        provider_message_id
      )
      when is_binary(provider_message_id) and provider_message_id != "" do
    Signal
    |> Ash.Query.filter(
      agent_uid == ^agent_uid and reply_binding_name == ^binding_name and
        conversation_id == ^conversation_id and status == :completed and
        (provider_message_id == ^provider_message_id or
           fragment(
             """
             jsonb_typeof(?->'entries') = 'array'
             AND EXISTS (
               SELECT 1
               FROM jsonb_array_elements(?->'entries') AS entry
               WHERE entry->>'provider_message_id' = ?
             )
             """,
             data,
             data,
             ^provider_message_id
           ))
    )
    |> Ash.Query.sort(available_at: :asc)
    |> Ankole.Ash.read!()
  end

  def signals_for_entry_in_tx(
        _repo,
        _agent_uid,
        _binding_name,
        _conversation_id,
        _provider_message_id
      ),
      do: []

  @doc """
  Accepts one stimulus and wakes its session after the transaction commits.

  A rejected stimulus gives its domain reason.
  """
  def accept(attrs) when is_map(attrs), do: attrs |> intake() |> Ankole.Errors.reason()
  def accept(_attrs), do: {:error, :invalid_request}

  @doc """
  Accepts a list of stimuli in one transaction and wakes their sessions after
  the transaction commits.

  A rejected stimulus rejects the full list and gives its domain reason.
  """
  def accept_all(attrs_list) when is_list(attrs_list),
    do: attrs_list |> intake_all() |> Ankole.Errors.reason()

  @doc "Publishes one Signal or a list of Signals that a transaction committed."
  def publish_committed(signals) do
    Ankole.Repo.assert_outside_transaction!()
    signals = List.wrap(signals)

    Enum.each(signals, fn signal ->
      Ankole.Observability.stage(
        "signal.intake.committed",
        Ankole.Observability.signal_attributes(signal),
        fn -> :ok end
      )

      Ankole.Sessions.Events.publish_status(signal.agent_uid, signal.session_id)
    end)

    Ankole.Sessions.deliver_events(signals)
    :ok
  end

  @doc "Accepts a stimulus with a durable EnsureDriver job in the caller's transaction."
  def accept_in_tx(repo, attrs) when is_map(attrs) do
    with :ok <- Ankole.Repo.require_transaction(repo), do: Intake.accept(repo, attrs)
  end

  def accept_in_tx(_repo, _attrs), do: {:error, :invalid_request}

  @doc """
  Accepts a list of stimuli in the caller's transaction.

  One query reads the existing Signals and one bulk insert writes the new
  Signals. The result has one Signal for each input, in the input order.
  """
  def accept_all_in_tx(repo, attrs_list) when is_list(attrs_list) do
    with :ok <- Ankole.Repo.require_transaction(repo) do
      if Enum.all?(attrs_list, &is_map/1),
        do: Intake.accept_all(repo, attrs_list),
        else: {:error, :invalid_request}
    end
  end
end
