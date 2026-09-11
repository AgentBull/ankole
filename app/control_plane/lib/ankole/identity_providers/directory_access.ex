defmodule Ankole.IdentityProviders.DirectoryAccess do
  @moduledoc """
  Durable provider events and reviewed directory removal evidence.
  """
  import Ecto.Query
  alias Ankole.IdentityProviders.{DirectoryEvent, DirectoryState, Jobs.ProcessDirectoryEvent}
  alias Ankole.Principals.{ExternalIdentity, HumanAccess}
  alias Ankole.Repo

  def state(provider_id), do: Repo.get_by(DirectoryState, provider_id: provider_id)

  def configuration_changed_in_tx(repo, provider_id) do
    repo.update_all(from(s in DirectoryState, where: s.provider_id == ^provider_id),
      inc: [revision: 1],
      set: [
        approved_scope_fingerprint: nil,
        snapshot_fingerprint: nil,
        status: :review_required,
        last_error: "Provider configuration changed; run and review a new directory sync",
        updated_at: DateTime.utc_now()
      ]
    )

    :ok
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
      Repo.all(
        from e in DirectoryEvent,
          where: e.provider_id == ^provider_id,
          order_by: [desc: e.inserted_at],
          limit: 100
      )

  def guard_subject(repo, provider_id, external_ids) do
    if repo.exists?(
         from e in DirectoryEvent,
           where:
             e.provider_id == ^provider_id and not is_nil(e.reason) and
               e.status in [:pending, :review_required] and
               fragment("? && ?::text[]", e.external_ids, ^external_ids)
       ), do: {:error, :provider_identity_requires_review}, else: :ok
  end

  def receive_event(provider_id, attrs) do
    Repo.transact(fn repo ->
      with {:ok, state} <- lock_state(repo, provider_id) do
        case repo.get_by(DirectoryEvent, provider_id: provider_id, event_id: attrs.event_id) do
          %DirectoryEvent{} = event ->
            {:ok, event}

          nil ->
            with {:ok, event} <-
                   %DirectoryEvent{}
                   |> Ecto.Changeset.change(Map.put(attrs, :provider_id, provider_id))
                   |> repo.insert(),
                 {:ok, _} <-
                   state
                   |> Ecto.Changeset.change(
                     revision: state.revision + 1,
                     approved_scope_fingerprint:
                       if(attrs.event_type == "contact.scope.updated_v3",
                         do: nil,
                         else: state.approved_scope_fingerprint
                       )
                   )
                   |> repo.update() do
              if is_binary(event.reason) do
                apply_restriction(repo, event)
              else
                with {:ok, _} <- Oban.insert(ProcessDirectoryEvent.new(%{"event_id" => event.id})),
                     do: {:ok, event}
              end
            end
        end
      end
    end)
  end

  def process_event(id) do
    case Repo.get(DirectoryEvent, id) do
      nil ->
        :ok

      %{status: status} when status in [:processed, :dismissed] ->
        :ok

      %{reason: reason} = event when is_binary(reason) ->
        case Repo.transact(fn repo ->
               with {:ok, _} <- lock_state(repo, event.provider_id),
                    do: apply_restriction(repo, repo.get!(DirectoryEvent, id))
             end) do
          {:ok, _} -> :ok
          error -> error
        end

      event ->
        case Ankole.IdentityProviders.DirectorySync.sync_provider(event.provider_id) do
          {:ok, _} ->
            event
            |> Ecto.Changeset.change(
              status: :processed,
              processed_at: DateTime.utc_now(),
              last_error: nil
            )
            |> Repo.update!()

            :ok

          {:error, reason} ->
            event |> Ecto.Changeset.change(last_error: error_label(reason)) |> Repo.update!()
            {:error, error_label(reason)}
        end
    end
  end

  def review_event(id, actor_uid, reason, action) when action in [:retry, :dismiss] do
    with true <- is_binary(reason) and String.trim(reason) != "",
         %DirectoryEvent{} = event <- Repo.get(DirectoryEvent, id) do
      case action do
        :retry ->
          with {:ok, _} <-
                 event
                 |> Ecto.Changeset.change(reviewed_by: actor_uid, review_reason: reason)
                 |> Repo.update(),
               do: process_event(id)

        :dismiss ->
          event
          |> Ecto.Changeset.change(
            status: :dismissed,
            reviewed_by: actor_uid,
            review_reason: reason,
            processed_at: DateTime.utc_now()
          )
          |> Repo.update()
      end
    else
      _ -> {:error, :invalid_review}
    end
  end

  def begin_sync(provider_id, expected_config \\ nil) do
    Repo.transact(fn repo ->
      with {:ok, state} <- lock_state(repo, provider_id),
           :ok <- current_configuration(repo, provider_id, expected_config) do
        state
        |> Ecto.Changeset.change(
          revision: state.revision + 1,
          last_started_at: DateTime.utc_now(),
          status: :syncing,
          last_error: nil
        )
        |> repo.update()
      end
    end)
  end

  defp current_configuration(_repo, _provider_id, nil), do: :ok

  defp current_configuration(repo, provider_id, expected) do
    alias Ankole.AppConfigure

    with {:ok, providers} <-
           AppConfigure.get_in_tx(repo, Ankole.IdentityProviders.Config.active_definition()),
         %{"enabled" => true, "config_key" => key} <-
           Enum.find(providers, &(&1["provider_id"] == provider_id)),
         {:ok, ^expected} <- AppConfigure.get_global_by_key_in_tx(repo, key) do
      :ok
    else
      _ -> {:error, :directory_configuration_changed}
    end
  end

  def finish_sync(ticket, scope, observations, opts) do
    Repo.transact(fn repo ->
      with {:ok, state} <- lock_state(repo, ticket.provider_id),
           true <- state.revision == ticket.revision do
        members = observations |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()

        previous =
          if state.last_success_at,
            do: Enum.uniq(state.member_uids ++ state.missing_uids),
            else: known_members(repo, state.provider_id)

        missing = Enum.sort(previous -- members)
        fingerprint = fingerprint(scope)
        removal_enabled = Keyword.fetch!(opts, :admission_scope) == "contact"
        reduction = if previous == [], do: 0, else: length(missing) * 100 / length(previous)

        review =
          removal_enabled and
            (state.approved_scope_fingerprint != fingerprint or members == [] or
               reduction > Keyword.fetch!(opts, :maximum_removal_percent))

        with :ok <- apply_observations(state.provider_id, observations, ticket),
             :ok <-
               if(removal_enabled and not review,
                 do:
                   restrict_missing(
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
            status: if(review, do: :review_required, else: :healthy),
            last_error:
              if(review,
                do: "Review the admission scope and missing people before automatic removal",
                else: nil
              )
          }

          with {:ok, updated} <- state |> Ecto.Changeset.change(attrs) |> repo.update() do
            if review, do: log_review(updated)
            {:ok, updated}
          end
        end
      else
        false -> {:ok, :superseded}
        error -> error
      end
    end)
  end

  def fail_sync(ticket, reason) do
    Repo.update_all(
      from(s in DirectoryState, where: s.id == ^ticket.id and s.revision == ^ticket.revision),
      set: [status: :failed, last_error: error_label(reason), updated_at: DateTime.utc_now()]
    )

    Ankole.Logging.warning(
      "identity_providers.directory.sync_failed",
      "Directory sync failed; check the provider connection and permissions",
      %{provider_id: ticket.provider_id, reason: error_label(reason)}
    )

    {:error, reason}
  end

  def approve_snapshot(provider_id, fingerprint, actor_uid, reason, confirm_removals) do
    Repo.transact(fn repo ->
      with true <- is_binary(reason) and String.trim(reason) != "",
           {:ok, state} <- lock_state(repo, provider_id),
           true <- state.snapshot_fingerprint == fingerprint and state.status == :review_required,
           true <- DateTime.diff(DateTime.utc_now(), state.last_success_at) < 30 * 60,
           true <- confirm_removals or state.missing_uids == [],
           :ok <-
             restrict_missing(
               provider_id,
               state.missing_uids,
               "review:" <> fingerprint,
               state.last_started_at
             ) do
        state
        |> Ecto.Changeset.change(
          approved_scope_fingerprint: state.scope_fingerprint,
          reviewed_by: actor_uid,
          reviewed_at: DateTime.utc_now(),
          review_reason: reason,
          missing_uids: [],
          status: :healthy,
          last_error: nil
        )
        |> repo.update()
      else
        false -> {:error, :directory_review_changed}
        error -> error
      end
    end)
  end

  defp lock_state(repo, provider_id) do
    with {:ok, _} <-
           %DirectoryState{}
           |> Ecto.Changeset.change(provider_id: provider_id)
           |> repo.insert(on_conflict: :nothing, conflict_target: :provider_id) do
      {:ok,
       repo.one!(
         from s in DirectoryState, where: s.provider_id == ^provider_id, lock: "FOR UPDATE"
       )}
    end
  end

  defp apply_restriction(repo, event) do
    uids =
      repo.all(
        from i in ExternalIdentity,
          where: i.provider == ^event.provider_id and i.external_id in ^event.external_ids,
          select: i.principal_uid,
          distinct: true
      )

    case uids do
      [uid] ->
        with {:ok, _} <-
               HumanAccess.restrict_from_provider(
                 uid,
                 event.provider_id,
                 event.reason,
                 event.event_id,
                 event.provider_time
               ) do
          event
          |> Ecto.Changeset.change(
            status: :processed,
            processed_at: DateTime.utc_now(),
            last_error: nil
          )
          |> repo.update()
        end

      _ ->
        Ankole.Logging.warning(
          "identity_providers.directory.identity_review_required",
          "Resolve the provider identity before retrying the event",
          %{provider_id: event.provider_id, event_id: event.event_id}
        )

        event
        |> Ecto.Changeset.change(
          status: :review_required,
          last_error: "Provider identity is missing or ambiguous; review the stored aliases"
        )
        |> repo.update()
    end
  end

  defp known_members(repo, provider_id),
    do:
      repo.all(
        from i in ExternalIdentity,
          where: i.provider == ^provider_id,
          select: i.principal_uid,
          distinct: true
      )

  defp apply_observations(provider_id, observations, ticket) do
    Enum.reduce_while(Enum.sort(observations), :ok, fn {uid, status}, :ok ->
      operation_id = "snapshot:" <> ticket.id <> ":" <> to_string(ticket.revision)

      result =
        case status do
          :healthy ->
            HumanAccess.verify_provider_recovery(uid, provider_id, operation_id)

          :unknown ->
            {:ok, :unchanged}

          reason ->
            HumanAccess.restrict_from_provider(
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

  defp restrict_missing(provider_id, uids, operation_id, time) do
    Enum.reduce_while(uids, :ok, fn uid, :ok ->
      case HumanAccess.restrict_from_provider(
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

  defp error_label(%FeishuOpenAPI.Error{code: code}), do: "Feishu error #{inspect(code)}"
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
