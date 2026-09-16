defmodule Ankole.Principals.HumanAccess do
  @moduledoc """
  Human restrictions and persistent credential revocation.
  """

  import Ecto.Query
  alias Ankole.AuthZ
  alias Ankole.AuthZ.Store
  alias Ankole.Principals
  alias Ankole.Principals.{AccessEvent, AccessRestriction, Principal}
  alias Ankole.Repo

  def check(uid, version) when is_binary(uid) and is_integer(version) do
    case Repo.get(Principal, uid) do
      %Principal{type: :human, status: :active, access_version: ^version} -> :ok
      _ -> {:error, :human_access_revoked}
    end
  end

  def check(_uid, _version), do: {:error, :human_access_revoked}

  def current_version(uid) do
    case Principals.get_principal(uid) do
      {:ok, %Principal{type: :human, status: :active, access_version: version}} ->
        {:ok, version}

      _ ->
        {:error, :human_access_revoked}
    end
  end

  def restrictions(uid) do
    Repo.all(from r in AccessRestriction, where: r.principal_uid == ^uid, order_by: r.inserted_at)
  end

  def history(uid) do
    Repo.all(
      from e in AccessEvent, where: e.principal_uid == ^uid, order_by: [desc: e.inserted_at]
    )
  end

  @doc """
  Gives an independently verified, active Human administrator access when none remains.
  Only the operator command calls this operation; browser setup does not use it.
  """
  def recover_admin(uid, operator, reason) when is_binary(operator) and operator != "" do
    Repo.transact(fn repo ->
      with {:ok, principal} <- AuthZ.recover_admin_in_tx(repo, uid),
           {:ok, _} <-
             record(repo, principal, principal, "operator_admin_recovery", %{
               source: "operator",
               reason: reason,
               operation_id: Ankole.Kernel.gen_uuid_v7(),
               details: %{"operator" => operator, "identity_verified" => true}
             }) do
        {:ok, principal}
      end
    end)
  end

  def disable(uid, reason, actor_uid, operation_id) do
    restrict(uid, %{
      source: "manual",
      reason: reason,
      actor_uid: actor_uid,
      operation_id: operation_id
    })
  end

  def restrict_from_provider(uid, provider_id, reason, operation_id, provider_time \\ nil)
      when is_binary(provider_id) and provider_id != "" do
    restrict(uid, %{
      source: "provider:" <> provider_id,
      reason: reason,
      operation_id: operation_id,
      provider_time: provider_time
    })
  end

  defp restrict(uid, attrs) do
    Repo.transact(fn repo ->
      with :ok <- lock_disable(repo, uid, attrs),
           {:ok, %Principal{type: :human} = principal} <-
             Store.fetch_principal_for_update(repo, uid) do
        case repo.get_by(AccessEvent,
               principal_uid: principal.uid,
               source: attrs.source,
               operation_id: attrs.operation_id
             ) do
          %AccessEvent{} ->
            {:ok, principal}

          nil ->
            if stale_provider_observation?(repo, principal.uid, attrs),
              do: {:ok, principal},
              else: restrict_in_tx(repo, principal, attrs)
        end
      else
        {:ok, %Principal{}} -> {:error, :not_human}
        error -> error
      end
    end)
  end

  defp lock_disable(_repo, uid, %{source: "manual", actor_uid: uid}),
    do: {:error, :cannot_disable_self}

  defp lock_disable(repo, uid, %{source: "manual"}),
    do: AuthZ.ensure_can_disable_principal(uid, repo)

  defp lock_disable(repo, _uid, %{source: "provider:" <> _}) do
    Store.lock_built_in_admin_group_for_update(repo, Ankole.AuthZ.Root.admin_group_name())
    :ok
  end

  defp restrict_in_tx(repo, principal, attrs) do
    restriction =
      repo.one(
        from r in AccessRestriction,
          where:
            r.principal_uid == ^principal.uid and r.source == ^attrs.source and
              r.reason == ^attrs.reason and is_nil(r.cleared_at)
      ) || %AccessRestriction{}

    version = principal.access_version + if(principal.status == :active, do: 1, else: 0)

    with {:ok, _restriction} <-
           restriction
           |> AccessRestriction.changeset(Map.put(attrs, :principal_uid, principal.uid))
           |> Ecto.Changeset.put_change(:recovery_verified_at, nil)
           |> repo.insert_or_update(),
         {:ok, disabled} <-
           principal
           |> Ecto.Changeset.change(
             status: :disabled,
             access_version: version,
             access_revoked_at:
               if(principal.status == :active,
                 do: DateTime.utc_now(),
                 else: principal.access_revoked_at
               )
           )
           |> repo.update(),
         {:ok, _event} <- record(repo, principal, disabled, "disable", attrs),
         :ok <-
           Ankole.OIDC.Sessions.revoke_human_in_tx(repo, disabled.uid, disabled.access_version),
         :ok <- Ankole.Principals.WorkCleanup.enqueue_in_tx(disabled.uid, disabled.access_version) do
      {:ok, disabled}
    end
  end

  defp stale_provider_observation?(repo, uid, %{
         source: "provider:" <> _ = source,
         provider_time: %DateTime{} = time
       }) do
    repo.exists?(
      from r in AccessRestriction,
        where: r.principal_uid == ^uid and r.source == ^source and r.recovery_verified_at > ^time
    )
  end

  defp stale_provider_observation?(_repo, _uid, _attrs), do: false

  def verify_provider_recovery(uid, provider_id, operation_id) do
    Repo.transact(fn repo ->
      with {:ok, principal} <- Store.fetch_principal_for_update(repo, uid) do
        source = "provider:" <> provider_id
        now = DateTime.utc_now()

        active =
          from r in AccessRestriction,
            where:
              r.principal_uid == ^principal.uid and r.source == ^source and is_nil(r.cleared_at)

        newly_verified? = repo.exists?(from r in active, where: is_nil(r.recovery_verified_at))
        repo.update_all(active, set: [recovery_verified_at: now, updated_at: now])

        if not newly_verified? do
          {:ok, principal}
        else
          record(repo, principal, principal, "provider_recovery_verified", %{
            source: source,
            reason: "current_provider_state_allows_recovery",
            operation_id: operation_id
          })
        end
      end
    end)
  end

  def clear_restriction(uid, restriction_id, actor_uid, reason, operation_id) do
    Repo.transact(fn repo ->
      with {:ok, principal} <- Store.fetch_principal_for_update(repo, uid) do
        case repo.get_by(AccessRestriction, id: restriction_id, principal_uid: uid) do
          nil ->
            {:error, :not_found}

          %AccessRestriction{cleared_at: cleared_at} when not is_nil(cleared_at) ->
            {:ok, principal}

          restriction ->
            with :ok <- recovery_allowed(restriction),
                 {:ok, _} <-
                   restriction
                   |> Ecto.Changeset.change(cleared_at: DateTime.utc_now())
                   |> repo.update() do
              record(repo, principal, principal, "clear_restriction", %{
                source: "manual",
                reason: reason,
                actor_uid: actor_uid,
                operation_id: operation_id,
                details: %{"restriction_id" => restriction.id}
              })
            end
        end
      end
    end)
  end

  def restore(uid, review_fingerprint, actor_uid, reason, operation_id) do
    Repo.transact(fn repo ->
      Store.lock_built_in_admin_group_for_update(repo, Ankole.AuthZ.Root.admin_group_name())

      with {:ok, %Principal{type: :human, status: :disabled} = principal} <-
             Store.fetch_principal_for_update(repo, uid),
           false <-
             repo.exists?(
               from r in AccessRestriction,
                 where: r.principal_uid == ^principal.uid and is_nil(r.cleared_at)
             ),
           {:ok, %{fingerprint: ^review_fingerprint} = review} <- AuthZ.restoration_review(uid),
           {:ok, restored} <-
             principal |> Principal.status_changeset(%{status: :active}) |> repo.update(),
           {:ok, _} <-
             record(repo, principal, restored, "restore", %{
               source: "manual",
               reason: reason,
               actor_uid: actor_uid,
               operation_id: operation_id,
               details: %{
                 "approved_permissions" => review.permissions,
                 "identity_verified" => true
               }
             }) do
        {:ok, restored}
      else
        true -> {:error, :active_restrictions}
        {:ok, %Principal{type: :human, status: :active} = principal} -> {:ok, principal}
        {:ok, %Principal{}} -> {:error, :not_human}
        {:ok, %{fingerprint: _}} -> {:error, :permission_review_changed}
        error -> error
      end
    end)
  end

  defp recovery_allowed(%AccessRestriction{source: "manual"}), do: :ok

  defp recovery_allowed(%AccessRestriction{
         source: "provider:" <> provider_id,
         principal_uid: uid,
         recovery_verified_at: %DateTime{} = time
       }) do
    if Ankole.IdentityProviders.DirectoryAccess.recovery_current?(provider_id, uid, time),
      do: :ok,
      else: {:error, :provider_recovery_not_verified}
  end

  defp recovery_allowed(_), do: {:error, :provider_recovery_not_verified}

  defp record(repo, before, after_state, action, attrs) do
    %AccessEvent{}
    |> Ecto.Changeset.change(
      Map.merge(
        Map.take(attrs, [
          :operation_id,
          :source,
          :reason,
          :actor_uid,
          :provider_time,
          :details
        ]),
        %{
          principal_uid: before.uid,
          action: action,
          previous_status: before.status,
          status: after_state.status,
          access_version: after_state.access_version
        }
      )
    )
    |> Ecto.Changeset.validate_required([:operation_id, :source, :reason])
    |> Ecto.Changeset.unique_constraint(:operation_id,
      name: :human_access_events_source_operation_id_principal_uid_index
    )
    |> repo.insert()
  end
end
