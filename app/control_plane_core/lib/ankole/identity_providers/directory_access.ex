defmodule Ankole.IdentityProviders.DirectoryAccess do
  @moduledoc """
  Durable provider events and reviewed directory removal evidence.

  Each write locks the provider's directory state first. It is a generic
  action of `DirectoryState` or `DirectoryEvent` that owns its transaction;
  the `_in_tx` functions are its steps.
  """
  require Ash.Query
  alias Ankole.IdentityProviders.DirectoryEvent
  alias Ankole.IdentityProviders.DirectoryState
  alias Ankole.IdentityProviders.Jobs.ProcessDirectoryEvent
  alias Ankole.Principals
  alias Ankole.Principals.HumanAccess

  @doc "Returns the directory snapshot and the recent event evidence."
  def console_view(id) do
    snapshot =
      case state(id) do
        nil ->
          nil

        value ->
          Map.take(value, [
            :provider_id,
            :status,
            :revision,
            :scope_fingerprint,
            :snapshot_fingerprint,
            :approved_scope_fingerprint,
            :member_uids,
            :missing_uids,
            :last_started_at,
            :last_success_at,
            :last_error,
            :reviewed_by,
            :reviewed_at,
            :review_reason
          ])
      end

    events =
      Enum.map(
        events(id),
        &Map.take(&1, [
          :id,
          :event_id,
          :event_type,
          :external_ids,
          :reason,
          :provider_time,
          :status,
          :last_error,
          :processed_at,
          :reviewed_by,
          :review_reason,
          :inserted_at
        ])
      )

    snapshot = if snapshot, do: Map.update!(snapshot, :reviewed_by, &actor_projection/1)

    events =
      Enum.map(events, &Map.update!(&1, :reviewed_by, fn actor -> actor_projection(actor) end))

    %{snapshot: snapshot, events: events}
  end

  defp actor_projection(nil), do: nil
  defp actor_projection(reference), do: Map.from_struct(reference)

  def state(provider_id),
    do: DirectoryState |> Ash.Query.filter(provider_id == ^provider_id) |> Ankole.Ash.read_one!()

  def configuration_changed_in_tx(_repo, provider_id) do
    DirectoryState
    |> Ash.Query.filter(provider_id == ^provider_id)
    |> update_states(:configuration_changed_in_tx, %{})
  end

  def recovery_current?(provider_id, uid, verified_at) do
    case state(provider_id) do
      %DirectoryState{
        status: :healthy,
        last_started_at: started,
        last_success_at: completed,
        member_uids: members
      }
      when not is_nil(completed) ->
        uid in members and DateTime.diff(DateTime.utc_now(), completed) < 30 * 60 and
          DateTime.compare(verified_at, started) != :lt

      _ ->
        false
    end
  end

  def events(provider_id),
    do:
      DirectoryEvent
      |> Ash.Query.filter(provider_id == ^provider_id)
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(100)
      |> Ankole.Ash.read!()

  def guard_subject(_repo, provider_id, external_ids) do
    DirectoryEvent
    |> Ash.Query.filter(
      provider_id == ^provider_id and not is_nil(reason) and
        status in [:pending, :review_required] and
        fragment("? && ?::text[]", external_ids, ^external_ids)
    )
    |> Ash.Query.limit(1)
    |> Ankole.Ash.read!()
    |> case do
      [] -> :ok
      [_event] -> {:error, :provider_identity_requires_review}
    end
  end

  def receive_event(provider_id, attrs) do
    Ankole.Ash.run_action(DirectoryEvent, :receive, %{provider_id: provider_id, attrs: attrs})
  end

  @doc false
  def receive_event_in_tx(repo, provider_id, attrs) do
    with {:ok, state} <- lock_state(provider_id) do
      case DirectoryEvent
           |> Ash.Query.filter(provider_id == ^provider_id and event_id == ^attrs.event_id)
           |> Ankole.Ash.read_one!() do
        %DirectoryEvent{} = event ->
          {:ok, event}

        nil ->
          with {:ok, event} <-
                 Ankole.Ash.create(
                   DirectoryEvent,
                   :receive_in_tx,
                   Map.put(attrs, :provider_id, provider_id)
                 ),
               {:ok, _} <-
                 Ankole.Ash.update(state, :receive_event_in_tx, %{
                   approved_scope_fingerprint:
                     if(attrs.event_type == "contact.scope.updated_v3",
                       do: nil,
                       else: state.approved_scope_fingerprint
                     )
                 }) do
            dispatch_directory_event(repo, event)
          end
      end
    end
  end

  defp dispatch_directory_event(repo, event) do
    if is_binary(event.reason) do
      apply_restriction(repo, event)
    else
      with {:ok, _} <- Oban.insert(ProcessDirectoryEvent.new(%{"event_id" => event.id})),
           do: {:ok, event}
    end
  end

  def process_event(id) do
    case get_event(id) do
      nil ->
        :ok

      %{status: status} when status in [:processed, :dismissed] ->
        :ok

      %{reason: reason} = event when is_binary(reason) ->
        case Ankole.Ash.run_action(DirectoryEvent, :apply_restriction, %{event: event}) do
          {:ok, _} -> :ok
          error -> error
        end

      event ->
        case Ankole.IdentityProviders.DirectorySync.sync_provider(event.provider_id) do
          {:ok, _} ->
            with {:ok, _event} <- update_open_event(event, :process_in_tx, %{}), do: :ok

          {:error, reason} ->
            with {:ok, _event} <-
                   update_open_event(event, :fail_in_tx, %{last_error: error_label(reason)}),
                 do: {:error, error_label(reason)}
        end
    end
  end

  def review_event(id, actor_uid, reason, action) when action in [:retry, :dismiss] do
    with true <- is_binary(reason) and String.trim(reason) != "",
         %DirectoryEvent{} = event <- get_event(id) do
      result =
        update_open_event(
          event,
          if(action == :retry, do: :review_in_tx, else: :dismiss_in_tx),
          %{reviewed_by: actor_uid, review_reason: reason},
          false
        )

      case {action, result} do
        {:retry, {:ok, _event}} -> process_event(id)
        {_action, result} -> result
      end
    else
      _ -> {:error, :invalid_review}
    end
  end

  def get_event(id),
    do: DirectoryEvent |> Ash.Query.filter(id == ^id) |> Ankole.Ash.read_one!()

  # A review always writes the event; the processing result does not change
  # an event that a reviewer or an earlier run closed.
  defp update_open_event(event, action, attrs, only_open? \\ true) do
    Ankole.Ash.run_action(DirectoryEvent, :update_open, %{
      event: event,
      action: action,
      attrs: attrs,
      only_open?: only_open?
    })
  end

  @doc false
  def update_open_event_in_tx(event, action, attrs, only_open?) do
    with {:ok, _state} <- lock_state(event.provider_id) do
      current = get_event(event.id)

      if only_open? and current.status in [:processed, :dismissed],
        do: {:ok, current},
        else: Ankole.Ash.update(current, action, attrs)
    end
  end

  def begin_sync(provider_id, expected_config \\ nil) do
    Ankole.Ash.run_action(DirectoryState, :begin_sync, %{
      provider_id: provider_id,
      expected_config: expected_config
    })
  end

  @doc false
  def begin_sync_in_tx(repo, provider_id, expected_config) do
    with {:ok, state} <- lock_state(provider_id),
         :ok <- current_configuration(repo, provider_id, expected_config) do
      Ankole.Ash.update(state, :begin_sync_in_tx, %{})
    end
  end

  defp current_configuration(_repo, _provider_id, nil), do: :ok

  defp current_configuration(repo, provider_id, expected) do
    alias Ankole.AppConfigure

    with {:ok, providers} <-
           AppConfigure.get_in_tx(repo, Ankole.IdentityProviders.Config.active_definition()),
         %{"enabled" => true, "config_key" => key} <-
           Enum.find(providers, &(&1["provider_id"] == provider_id)),
         {:ok, ^expected} <- AppConfigure.get_tenant_by_key_in_tx(repo, key) do
      :ok
    else
      _ -> {:error, :directory_configuration_changed}
    end
  end

  def finish_sync(ticket, scope, observations, opts) do
    Ankole.Ash.run_action(DirectoryState, :finish_sync, %{
      ticket: ticket,
      scope: scope,
      observations: observations,
      opts: opts
    })
  end

  @doc false
  def finish_sync_in_tx(repo, ticket, scope, observations, opts) do
    with {:ok, state} <- lock_state(ticket.provider_id),
         true <- state.revision == ticket.revision do
      members = observations |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()

      previous =
        if state.last_success_at,
          do: Enum.uniq(state.member_uids ++ state.missing_uids),
          else: known_members(state.provider_id)

      missing = Enum.sort(previous -- members)
      fingerprint = fingerprint(scope)
      removal_enabled = Keyword.fetch!(opts, :admission_scope) == "contact"
      reduction = if previous == [], do: 0, else: length(missing) * 100 / length(previous)

      review =
        removal_enabled and
          (state.approved_scope_fingerprint != fingerprint or members == [] or
             reduction > Keyword.fetch!(opts, :maximum_removal_percent))

      with :ok <- apply_observations(repo, state.provider_id, observations, ticket),
           :ok <-
             if(removal_enabled and not review,
               do:
                 restrict_missing(
                   repo,
                   state.provider_id,
                   missing,
                   "sync:" <> ticket.id <> ":" <> to_string(ticket.revision),
                   ticket.last_started_at
                 ),
               else: :ok
             ) do
        attrs = %{
          member_uids: members,
          missing_uids: if(review, do: missing, else: []),
          scope_fingerprint: fingerprint,
          snapshot_fingerprint: fingerprint({ticket.revision, fingerprint, members, missing}),
          last_success_at: DateTime.utc_now(),
          last_error:
            if(review,
              do: "Review the admission scope and missing people before automatic removal",
              else: nil
            )
        }

        commit_sync_result(state, attrs, review)
      end
    else
      false -> {:ok, :superseded}
      error -> error
    end
  end

  defp commit_sync_result(state, attrs, review) do
    action = if(review, do: :review_snapshot_in_tx, else: :complete_sync_in_tx)

    with {:ok, updated} <- Ankole.Ash.update(state, action, attrs) do
      if review, do: log_review(updated)
      {:ok, updated}
    end
  end

  def fail_sync(ticket, reason) do
    :ok =
      DirectoryState
      |> Ash.Query.filter(id == ^ticket.id and revision == ^ticket.revision)
      |> update_states(:fail_sync_in_tx, %{last_error: error_label(reason)})

    Ankole.Logging.warning(
      "identity_providers.directory.sync_failed",
      "Directory sync failed; check the provider connection and permissions",
      %{provider_id: ticket.provider_id, reason: error_label(reason)}
    )

    {:error, reason}
  end

  def approve_snapshot(provider_id, fingerprint, actor_uid, reason, confirm_removals) do
    Ankole.Ash.run_action(DirectoryState, :approve_snapshot, %{
      provider_id: provider_id,
      fingerprint: fingerprint,
      actor: actor_uid,
      reason: reason,
      confirm_removals: confirm_removals
    })
  end

  @doc false
  def approve_snapshot_in_tx(repo, provider_id, fingerprint, actor_uid, reason, confirm_removals) do
    with true <- is_binary(reason) and String.trim(reason) != "",
         {:ok, state} <- lock_state(provider_id),
         true <- state.snapshot_fingerprint == fingerprint and state.status == :review_required,
         true <- DateTime.diff(DateTime.utc_now(), state.last_success_at) < 30 * 60,
         true <- confirm_removals or state.missing_uids == [],
         :ok <-
           restrict_missing(
             repo,
             provider_id,
             state.missing_uids,
             "review:" <> fingerprint,
             state.last_started_at
           ) do
      Ankole.Ash.update(state, :approve_snapshot_in_tx, %{
        approved_scope_fingerprint: state.scope_fingerprint,
        reviewed_by: actor_uid,
        review_reason: reason
      })
    else
      false -> {:error, :directory_review_changed}
      error -> error
    end
  end

  defp lock_state(provider_id) do
    with {:ok, _} <-
           Ankole.Ash.create(DirectoryState, :ensure_in_tx, %{provider_id: provider_id}) do
      {:ok,
       DirectoryState
       |> Ash.Query.filter(provider_id == ^provider_id)
       |> Ash.Query.lock(:for_update)
       |> Ankole.Ash.read_one!()}
    end
  end

  defp update_states(query, action, attrs) do
    case Ankole.Ash.update_where(query, action, attrs) do
      {:ok, _states} -> :ok
      {:error, error} -> raise error
    end
  end

  @doc false
  def apply_restriction_in_tx(repo, event) do
    with {:ok, _} <- lock_state(event.provider_id),
         do: apply_restriction(repo, get_event(event.id))
  end

  defp apply_restriction(_repo, %{status: status} = event)
       when status in [:processed, :dismissed],
       do: {:ok, event}

  defp apply_restriction(repo, event) do
    uids =
      identity_owners(external_id: [in: event.external_ids], provider: event.provider_id)

    case uids do
      [uid] ->
        with {:ok, _} <-
               HumanAccess.restrict_from_provider_in_tx(
                 repo,
                 uid,
                 event.provider_id,
                 event.reason,
                 event.event_id,
                 event.provider_time
               ) do
          Ankole.Ash.update(event, :process_in_tx, %{})
        end

      _ ->
        Ankole.Logging.warning(
          "identity_providers.directory.identity_review_required",
          "Resolve the provider identity before retrying the event",
          %{provider_id: event.provider_id, event_id: event.event_id}
        )

        Ankole.Ash.update(event, :require_review_in_tx, %{
          last_error: "Provider identity is missing or ambiguous; review the stored aliases"
        })
    end
  end

  defp known_members(provider_id), do: identity_owners(provider: provider_id)

  # The Principals that own the external identities of a provider filter.
  defp identity_owners(filter) do
    [query: [filter: filter]]
    |> Principals.list_external_identities!()
    |> Enum.map(& &1.principal_uid)
    |> Enum.uniq()
  end

  defp apply_observations(repo, provider_id, observations, ticket) do
    Enum.reduce_while(Enum.sort(observations), :ok, fn {uid, status}, :ok ->
      operation_id = "snapshot:" <> ticket.id <> ":" <> to_string(ticket.revision)

      result =
        case status do
          :healthy ->
            HumanAccess.verify_provider_recovery_in_tx(repo, uid, provider_id, operation_id)

          :unknown ->
            {:ok, :unchanged}

          reason ->
            HumanAccess.restrict_from_provider_in_tx(
              repo,
              uid,
              provider_id,
              reason,
              operation_id,
              ticket.last_started_at
            )
        end

      case result do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp restrict_missing(repo, provider_id, uids, operation_id, time) do
    Enum.reduce_while(uids, :ok, fn uid, :ok ->
      case HumanAccess.restrict_from_provider_in_tx(
             repo,
             uid,
             provider_id,
             "directory_removal",
             operation_id,
             time
           ) do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp fingerprint(value),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(value)) |> Base.encode16(case: :lower)

  defp error_label({:provider_error, label}) when is_binary(label), do: label
  defp error_label(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_label(_), do: "Directory collection or write failed"

  defp log_review(state),
    do:
      Ankole.Logging.warning(
        "identity_providers.directory.review_required",
        "Review the directory snapshot before automatic removal",
        %{provider_id: state.provider_id, missing_count: length(state.missing_uids)}
      )
end
