defmodule Ankole.Principals.HumanAccess do
  @moduledoc """
  Human restrictions and persistent credential revocation.

  Public functions own the transaction. Their `_in_tx` steps compose resource
  actions for restrictions, credentials, sessions, and cleanup work.
  """

  require Ash.Query
  alias Ankole.AuthZ
  alias Ankole.AuthZ.Store
  alias Ankole.Principals
  alias Ankole.Principals.AccessEvent
  alias Ankole.Principals.AccessRestriction
  alias Ankole.Principals.Principal
  alias Ankole.Repo

  @doc "Returns the access, permission review, history, and cleanup state of a Human."
  def console_view(uid) do
    with {:ok, %{type: :human} = principal} <- Principals.get_principal(uid),
         {:ok, review} <- AuthZ.restoration_review(uid) do
      {:ok,
       %{
         uid: uid,
         status: principal.status,
         access_version: principal.access_version,
         access_revoked_at: principal.access_revoked_at,
         permission_review: review,
         restrictions:
           Enum.map(
             restrictions(uid),
             &Map.take(&1, [
               :id,
               :source,
               :disposition,
               :reason,
               :provider_time,
               :recovery_verified_at,
               :cleared_at,
               :inserted_at
             ])
           ),
         history:
           Enum.map(
             history(uid),
             fn event ->
               event
               |> Map.take([
                 :id,
                 :source,
                 :action,
                 :reason,
                 :actor,
                 :access_version,
                 :details,
                 :inserted_at
               ])
               |> Map.update!(:actor, fn actor -> actor && Map.from_struct(actor) end)
             end
           ),
         work: Ankole.Principals.WorkAccess.list_for_human(uid),
         cleanup_jobs:
           Enum.map(
             Ankole.Principals.WorkCleanup.jobs_for_human(uid),
             &Map.take(&1, [
               :id,
               :state,
               :attempt,
               :max_attempts,
               :scheduled_at,
               :completed_at,
               :discarded_at
             ])
           )
       }}
    else
      {:ok, _} -> {:error, :not_human}
      {:error, reason} -> {:error, reason}
    end
  end

  def check(uid, version) when is_binary(uid) and is_integer(version) do
    case Principals.get_principal_across_tenants(uid) do
      {:ok, %Principal{type: :human, status: :active, access_version: ^version}} -> :ok
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
    AccessRestriction
    |> Ash.Query.filter(principal_uid == ^uid)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ankole.Ash.read!()
  end

  def history(uid) do
    AccessEvent
    |> Ash.Query.filter(principal_uid == ^uid)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ankole.Ash.read!()
  end

  @doc """
  Gives an independently verified, active Human administrator access when none remains.
  Only the operator command calls this operation; browser setup does not use it.
  """
  def recover_admin(uid, operator, reason) when is_binary(operator) and operator != "" do
    Repo.transact_top_level(fn -> recover_admin_in_tx(uid, operator, reason) end)
  end

  @doc false
  def recover_admin_in_tx(uid, operator, reason) do
    with {:ok, _} <- Ankole.Tenants.lock_administration(),
         {:ok, tenant} <- Ankole.Tenants.privileged() do
      Repo.with_tenant(tenant.id, fn -> recover_site_admin(uid, operator, reason) end)
    end
  end

  defp recover_site_admin(uid, operator, reason) do
    with {:ok, principal} <- AuthZ.recover_admin_in_tx(uid),
         {:ok, _} <-
           record(principal, principal, "operator_admin_recovery", %{
             source: "operator",
             reason: reason,
             operation_id: Ash.UUIDv7.generate(),
             details: %{"operator" => operator, "identity_verified" => true}
           }) do
      {:ok, principal}
    end
  end

  def recover_pod_admin(tenant_id, uid, operator, reason)
      when is_binary(operator) and operator != "" do
    Repo.with_tenant(tenant_id, fn ->
      Repo.transact_top_level(fn ->
        with {:ok, _} <- Ankole.Tenants.lock_administration(),
             {:ok, principal} <- Ankole.AuthZ.Recovery.recover_pod_admin_in_tx(uid),
             {:ok, _} <-
               record(principal, principal, "operator_admin_recovery", %{
                 source: "operator",
                 reason: reason,
                 operation_id: Ash.UUIDv7.generate(),
                 details: %{
                   "operator" => operator,
                   "identity_verified" => true,
                   "group" => "pod_admin"
                 }
               }),
             do: {:ok, principal}
      end)
    end)
  end

  def exit(%Ankole.AuthZ.Actor{} = actor) do
    uid = Ankole.AuthZ.Actor.uid(actor)

    Repo.transact_top_level(fn ->
      with false <- Ankole.IdentityProviders.directory_managed_member?(uid),
           do:
             restrict_in_tx(uid, %{
               source: "manual",
               disposition: :offboarded,
               reason: "member_exit",
               actor: Ankole.ActorRef.from_actor(actor),
               self_exit: true,
               operation_id: Ankole.Ecto.UUIDv7.autogenerate()
             }),
           else: (true -> {:error, :directory_managed_member})
    end)
  end

  def disable(uid, reason, actor_uid, operation_id, disposition \\ :suspended)
      when disposition in [:suspended, :offboarded] do
    restrict(uid, %{
      source: "manual",
      disposition: disposition,
      reason: reason,
      actor: actor_uid,
      operation_id: operation_id
    })
  end

  def restrict_from_provider(uid, provider_id, reason, operation_id, provider_time \\ nil)
      when is_binary(provider_id) and provider_id != "" do
    restrict(uid, %{
      source: "provider:" <> provider_id,
      disposition: provider_disposition(reason),
      reason: reason,
      operation_id: operation_id,
      provider_time: provider_time
    })
  end

  @doc false
  def restrict_from_provider_in_tx(uid, provider_id, reason, operation_id, provider_time) do
    restrict_in_tx(uid, %{
      source: "provider:" <> provider_id,
      disposition: provider_disposition(reason),
      reason: reason,
      operation_id: operation_id,
      provider_time: provider_time
    })
  end

  defp restrict(uid, attrs),
    do: Repo.transact_top_level(fn -> restrict_in_tx(uid, attrs) end)

  defp provider_disposition("suspended"), do: :suspended
  defp provider_disposition(_reason), do: :offboarded

  def offboarded_in_current_cycle?(%Principal{status: :disabled, uid: uid}) do
    last_restore =
      AccessEvent
      |> Ash.Query.filter(principal_uid == ^uid and action == "restore")
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(1)
      |> Ankole.Ash.read_one!()

    query =
      AccessRestriction
      |> Ash.Query.filter(principal_uid == ^uid and disposition == :offboarded)

    query =
      if last_restore do
        Ash.Query.filter(query, is_nil(cleared_at) or cleared_at > ^last_restore.inserted_at)
      else
        query
      end

    Ankole.Ash.exists?(query)
  end

  def offboarded_in_current_cycle?(%Principal{}), do: false

  @doc false
  def restrict_in_tx(uid, attrs) do
    with :ok <- lock_disable(uid, attrs),
         {:ok, %Principal{type: :human} = principal} <-
           Principals.lock_principal_in_tx(uid) do
      case AccessEvent
           |> Ash.Query.filter(
             principal_uid == ^principal.uid and source == ^attrs.source and
               operation_id == ^attrs.operation_id
           )
           |> Ankole.Ash.read_one!() do
        %AccessEvent{} ->
          {:ok, principal}

        nil ->
          if stale_provider_observation?(principal.uid, attrs),
            do: {:ok, principal},
            else: revoke_in_tx(principal, attrs)
      end
    else
      {:ok, %Principal{}} -> {:error, :not_human}
      error -> error
    end
  end

  defp lock_disable(uid, %{source: "manual", self_exit: true}),
    do: AuthZ.ensure_can_disable_principal(uid)

  defp lock_disable(uid, %{source: "manual", actor: %Ankole.ActorRef{uid: uid}}),
    do: {:error, :cannot_disable_self}

  defp lock_disable(uid, %{source: "manual"}),
    do: AuthZ.ensure_can_disable_principal(uid)

  defp lock_disable(_uid, %{source: "provider:" <> _}) do
    Store.lock_admin_groups_for_update()
    :ok
  end

  defp revoke_in_tx(principal, attrs) do
    restriction =
      AccessRestriction
      |> Ash.Query.filter(
        principal_uid == ^principal.uid and source == ^attrs.source and
          disposition == ^attrs.disposition and reason == ^attrs.reason and is_nil(cleared_at)
      )
      |> Ankole.Ash.read_one!() || %AccessRestriction{}

    with {:ok, _restriction} <-
           persist_restriction(restriction, Map.put(attrs, :principal_uid, principal.uid)),
         {:ok, disabled} <-
           Ankole.Ash.update(principal, :revoke_human_in_tx, %{}),
         {:ok, released} <- release_for_disposition(principal, attrs.disposition),
         {:ok, _event} <-
           record(principal, disabled, "disable", Map.put(attrs, :released_identifiers, released)),
         :ok <-
           Ankole.OIDC.Sessions.revoke_human_in_tx(disabled.uid, disabled.access_version),
         :ok <- Ankole.Principals.WorkCleanup.enqueue_in_tx(disabled.uid, disabled.access_version) do
      {:ok, disabled}
    end
  end

  defp release_for_disposition(principal, :offboarded),
    do:
      Ankole.Authn.Info.run_add_on(Principal, :offboarding_release, :release, %{
        principal: principal
      })

  defp release_for_disposition(_principal, :suspended), do: {:ok, []}

  defp persist_restriction(%AccessRestriction{id: nil}, attrs),
    do:
      Ankole.Ash.create(
        AccessRestriction,
        :restrict_in_tx,
        Map.take(attrs, [
          :principal_uid,
          :source,
          :disposition,
          :reason,
          :operation_id,
          :provider_time
        ])
      )

  defp persist_restriction(restriction, attrs),
    do:
      Ankole.Ash.update(
        restriction,
        :repeat_restriction_in_tx,
        Map.take(attrs, [:operation_id, :provider_time])
      )

  defp stale_provider_observation?(uid, %{
         source: "provider:" <> _ = source,
         provider_time: %DateTime{} = time
       }) do
    AccessRestriction
    |> Ash.Query.filter(
      principal_uid == ^uid and source == ^source and recovery_verified_at > ^time
    )
    |> Ankole.Ash.exists?()
  end

  defp stale_provider_observation?(_uid, _attrs), do: false

  def verify_provider_recovery(uid, provider_id, operation_id) do
    Repo.transact_top_level(fn ->
      verify_provider_recovery_in_tx(uid, provider_id, operation_id)
    end)
  end

  @doc false
  def verify_provider_recovery_in_tx(uid, provider_id, operation_id) do
    with {:ok, principal} <- Principals.lock_principal_in_tx(uid) do
      source = "provider:" <> provider_id
      now = DateTime.utc_now()

      active =
        AccessRestriction
        |> Ash.Query.filter(
          principal_uid == ^principal.uid and source == ^source and is_nil(cleared_at)
        )
        |> Ankole.Ash.read!()

      newly_verified? = Enum.any?(active, &is_nil(&1.recovery_verified_at))

      Enum.each(active, fn restriction ->
        {:ok, _} =
          Ankole.Ash.update(restriction, :verify_recovery_in_tx, %{recovery_verified_at: now})
      end)

      if not newly_verified? do
        {:ok, principal}
      else
        record(principal, principal, "provider_recovery_verified", %{
          source: source,
          reason: "current_provider_state_allows_recovery",
          operation_id: operation_id
        })
      end
    end
  end

  def clear_restriction(uid, restriction_id, actor_uid, reason, operation_id) do
    Repo.transact_top_level(fn ->
      clear_restriction_in_tx(uid, restriction_id, actor_uid, reason, operation_id)
    end)
  end

  @doc false
  def clear_restriction_in_tx(uid, restriction_id, actor_uid, reason, operation_id) do
    with {:ok, principal} <- Principals.lock_principal_in_tx(uid) do
      case fetch_restriction(restriction_id, principal.uid) do
        nil ->
          {:error, :not_found}

        %AccessRestriction{cleared_at: cleared_at} when not is_nil(cleared_at) ->
          {:ok, principal}

        restriction ->
          with :ok <- recovery_allowed(restriction),
               {:ok, _} <-
                 Ankole.Ash.update(restriction, :clear_in_tx, %{cleared_at: DateTime.utc_now()}) do
            record(principal, principal, "clear_restriction", %{
              source: "manual",
              reason: reason,
              actor: actor_uid,
              operation_id: operation_id,
              details: %{"restriction_id" => restriction.id}
            })
          end
      end
    end
  end

  defp fetch_restriction(restriction_id, uid) do
    case Ecto.UUID.cast(restriction_id) do
      {:ok, id} ->
        AccessRestriction
        |> Ash.Query.filter(id == ^id and principal_uid == ^uid)
        |> Ankole.Ash.read_one!()

      :error ->
        nil
    end
  end

  def restore(uid, review_fingerprint, actor_uid, reason, operation_id) do
    Repo.transact_top_level(fn ->
      restore_in_tx(uid, review_fingerprint, actor_uid, reason, operation_id)
    end)
  end

  @doc false
  def restore_in_tx(uid, review_fingerprint, actor_uid, reason, operation_id) do
    Store.lock_built_in_admin_group_for_update(Ankole.AuthZ.Root.admin_group_name())

    with {:ok, %Principal{type: :human, status: :disabled} = principal} <-
           Principals.lock_principal_in_tx(uid),
         :ok <- tenant_allows_restoration(principal.tenant_id),
         false <-
           AccessRestriction
           |> Ash.Query.filter(principal_uid == ^principal.uid and is_nil(cleared_at))
           |> Ankole.Ash.exists?(),
         {:ok, %{fingerprint: ^review_fingerprint} = review} <- AuthZ.restoration_review(uid),
         {:ok, restored} <-
           Ankole.Ash.update(principal, :enable_in_tx, %{}),
         {:ok, _} <-
           record(principal, restored, "restore", %{
             source: "manual",
             reason: reason,
             actor: actor_uid,
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
  end

  defp tenant_allows_restoration(tenant_id) do
    case Ankole.Tenants.get(tenant_id) do
      {:ok, %{deleting_at: nil}} -> :ok
      _ -> {:error, :tenant_deleting}
    end
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

  defp record(before, after_state, action, attrs) do
    Ankole.Ash.create(
      AccessEvent,
      :record_in_tx,
      Map.merge(
        Map.take(attrs, [
          :operation_id,
          :source,
          :reason,
          :actor,
          :provider_time,
          :released_identifiers,
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
  end
end
