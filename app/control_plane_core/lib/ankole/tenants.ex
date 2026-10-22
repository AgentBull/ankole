defmodule Ankole.Tenants do
  @moduledoc """
  Durable tenant lifecycle and the single site-administration assignment.

  This module is the Tenants domain. A lifecycle change locks the site
  administration and the tenant row, so it is a generic action of
  `Ankole.Tenants.Tenant` that owns its transaction. The `_in_tx` functions
  let another domain's action do the same steps in its own transaction.
  """
  use Ankole.Ash.Domain

  require Ash.Query

  alias Ankole.{AppConfigure, Principals, Repo}
  alias Ankole.AuthZ.Grants
  alias Ankole.AuthZ.Root
  alias Ankole.AuthZ.Store
  alias Ankole.Tenants.Tenant

  resources do
    resource Tenant do
      define(:get_tenant, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_tenants, action: :read)
    end
  end

  @privileged_key "tenants.privileged_tenant_id"

  def privileged_definition do
    AppConfigure.define(
      key: @privileged_key,
      scope: :global,
      encrypted: false,
      console_writable: false,
      schema:
        Ankole.AppConfigure.Schema.new(fn value ->
          case Ecto.UUID.cast(value) do
            {:ok, id} -> {:ok, id}
            :error -> {:error, :invalid_tenant_id}
          end
        end),
      description: "ID of the tenant whose siteadmin group administers this site."
    )
  end

  def privileged do
    with {:ok, id} <- AppConfigure.get_global_by_key_in_tx(Repo, @privileged_key),
         {:ok, %Tenant{} = tenant} <- get_tenant(id) do
      {:ok, tenant}
    else
      _missing -> {:error, :privileged_tenant_missing}
    end
  end

  def list do
    Tenant
    |> Ash.Query.sort(inserted_at: :asc, id: :asc)
    |> Ankole.Ash.read!()
  end

  def get(id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, %Tenant{} = tenant} <- get_tenant(id),
         do: {:ok, tenant},
         else: (_ -> {:error, :not_found})
  end

  @doc "Finds an exact slug whose tenant accepts new work."
  def active_by_slug(slug) when is_binary(slug) do
    with {:ok, %Tenant{} = tenant} <-
           Tenant |> Ash.Query.filter(slug == ^slug) |> Ankole.Ash.read_one(),
         true <- accepting_work?(tenant),
         do: {:ok, tenant},
         else: (_ -> {:error, :not_found})
  end

  @doc "Runs a site fan-out without letting one tenant's failure skip another tenant."
  def map_active(fun) when is_function(fun, 0) do
    Tenant
    |> Ash.Query.filter(is_nil(suspended_at) and is_nil(deleting_at))
    |> Ash.Query.sort(inserted_at: :asc, id: :asc)
    |> Ankole.Ash.read!()
    |> map(fun)
  end

  @doc "Runs retention work in every tenant, including suspended and deleting tenants."
  def map_all(fun) when is_function(fun, 0), do: map(list(), fun)

  defp map(tenants, fun) do
    Enum.map(tenants, fn tenant ->
      result =
        Repo.with_tenant(tenant.id, fn ->
          try do
            case fun.() do
              {:error, reason} = error ->
                log_fanout_failure(tenant.id, :error, reason, [])
                error

              result ->
                result
            end
          rescue
            error ->
              log_fanout_failure(tenant.id, :error, error, __STACKTRACE__)
              {:error, {:exception, Exception.message(error)}}
          catch
            kind, reason ->
              log_fanout_failure(tenant.id, kind, reason, __STACKTRACE__)
              {:error, {kind, reason}}
          end
        end)

      {tenant.id, result}
    end)
  end

  defp log_fanout_failure(tenant_id, kind, reason, stacktrace) do
    Ankole.Logging.warning(
      "tenants.site_fanout_failed",
      "Site work failed for one tenant",
      Ankole.Logging.failure_fields(kind, reason, stacktrace) |> Map.put(:tenant_id, tenant_id)
    )
  end

  @doc false
  def fanout_result(results) do
    errors = for {tenant_id, {:error, reason}} <- results, do: {tenant_id, reason}

    case errors do
      [] -> :ok
      errors -> {:error, {:tenant_failures, errors}}
    end
  end

  @doc "Checks a loaded tenant, or reads its current state by ID, for new work."
  def accepting_work?(%Tenant{suspended_at: nil, deleting_at: nil}), do: true
  def accepting_work?(%Tenant{}), do: false

  def accepting_work?(id) do
    case get(id) do
      {:ok, tenant} -> accepting_work?(tenant)
      _ -> false
    end
  end

  @doc "Runs one inbound event in its tenant, unless the tenant is suspended or deleting."
  def dispatch_inbound(tenant_id, fun) when is_function(fun, 0),
    do: Repo.with_tenant(tenant_id, fn -> dispatch_inbound(fun) end)

  @doc "Drops new inbound events while the selected tenant is suspended or deleting."
  def dispatch_inbound(fun) when is_function(fun, 0) do
    tenant_id = Repo.tenant_id!()

    if accepting_work?(tenant_id) do
      fun.()
    else
      Ankole.Logging.info(
        "signals.inbound.tenant_suspended",
        "Tenant does not accept inbound events",
        %{tenant_id: tenant_id}
      )

      {:ok, []}
    end
  end

  def check_work_admission(id) do
    if accepting_work?(id), do: :ok, else: {:error, :tenant_suspended}
  end

  @doc "Serializes new attempt admission with tenant suspension and deletion."
  def check_work_admission_in_tx(_repo, id) do
    case Tenant
         |> Ash.Query.filter(id == ^id)
         |> Ash.Query.lock("FOR SHARE")
         |> Ankole.Ash.read_one() do
      {:ok, %Tenant{} = tenant} -> check_work_admission(tenant)
      {:ok, nil} -> {:error, :tenant_suspended}
      {:error, _reason} = error -> error
    end
  end

  # Staged: test setup and the SaaS Pod creation still call this function in
  # their transaction. Change it to a generic action when they use
  # `create_in_tx/2`.
  def create(attrs), do: Repo.transact(fn repo -> create_in_tx(repo, attrs) end)

  @doc false
  def create_in_tx(repo, attrs) do
    with {:ok, tenant} <-
           Ankole.Ash.create(Tenant, :create_in_tx, Map.take(attrs, [:slug, :display_name])) do
      Repo.with_tenant(tenant.id, fn ->
        with :ok <- ensure_scaffold_in_tx(repo, tenant),
             :ok <- Ankole.Pod.Access.initialize_space(repo),
             {:ok, _} <-
               Ankole.Brain.SchemaPacks.install_packs(Map.get(attrs, :brain_packs, [])) do
          {:ok, tenant}
        end
      end)
    end
  end

  def ensure_scaffold(%Tenant{} = tenant),
    do: Ankole.Ash.run_action(Tenant, :ensure_scaffold, %{tenant: tenant})

  @doc false
  def ensure_scaffold_in_tx(repo, %Tenant{} = tenant) do
    Repo.with_tenant(tenant.id, fn ->
      with {:ok, _} <- lock_administration(repo),
           {:ok, _} <- Root.ensure_all_humans_group(repo),
           {:ok, _} <- Principals.ensure_system_principal_in_tx(repo),
           :ok <- ensure_privileged_group(repo, tenant) do
        :ok
      end
    end)
  end

  defp ensure_privileged_group(repo, tenant) do
    case privileged() do
      {:ok, %Tenant{id: id}} when id == tenant.id ->
        with {:ok, group} <- Root.ensure_site_admin_group(repo),
             {:ok, _} <- Grants.upsert_console_admin_grants(repo, group),
             do: :ok

      {:ok, _} ->
        :ok

      error ->
        error
    end
  end

  def update(%Tenant{id: id}, attrs),
    do: Ankole.Ash.run_action(Tenant, :change_profile, %{id: id, attrs: attrs})

  def suspend(%Tenant{id: id}), do: Ankole.Ash.run_action(Tenant, :suspend, %{id: id})
  def resume(%Tenant{id: id}), do: Ankole.Ash.run_action(Tenant, :resume, %{id: id})
  def delete(%Tenant{id: id}), do: Ankole.Ash.run_action(Tenant, :begin_delete, %{id: id})

  @doc false
  def change_profile_in_tx(repo, id, attrs) do
    with {:ok, _} <- lock_administration(repo),
         {:ok, tenant} <- lock_tenant(id),
         :ok <- not_deleting(tenant) do
      Ankole.Ash.update(tenant, :profile_in_tx, Map.take(attrs, [:slug, :display_name]))
    end
  end

  @doc false
  def suspend_in_tx(repo, id) do
    with {:ok, privileged_id} <- lock_administration(repo),
         {:ok, tenant} <- lock_tenant(id),
         :ok <- not_deleting(tenant),
         :ok <- not_privileged(tenant, privileged_id) do
      Ankole.Ash.update(tenant, :suspend_in_tx, %{})
    end
  end

  @doc false
  def resume_in_tx(repo, id) do
    with {:ok, _} <- lock_administration(repo),
         {:ok, tenant} <- lock_tenant(id),
         :ok <- not_deleting(tenant) do
      Ankole.Ash.update(tenant, :resume_in_tx, %{})
    end
  end

  @doc false
  def begin_delete_in_tx(repo, id) do
    with {:ok, privileged_id} <- lock_administration(repo),
         {:ok, tenant} <- lock_tenant(id),
         :ok <- not_privileged(tenant, privileged_id),
         {:ok, tenant} <- Ankole.Ash.update(tenant, :begin_delete_in_tx, %{}),
         {:ok, _} <- Ankole.Tenants.Jobs.Delete.new(%{tenant_id: tenant.id}) |> Oban.insert() do
      {:ok, tenant}
    end
  end

  def transfer_site_administration(%Tenant{id: id}, uid) do
    case Ankole.Ash.run_action(Tenant, :transfer_site_administration, %{id: id, uid: uid}) do
      {:ok, {tenant, _write}} -> {:ok, tenant}
      error -> error
    end
  end

  @doc false
  def transfer_site_administration_in_tx(repo, id, uid) do
    with {:ok, privileged_id} <- lock_administration(repo),
         {:ok, target} <- lock_tenant(id),
         :ok <- not_privileged(target, privileged_id),
         true <- accepting_work?(target),
         {:ok, _} <-
           Repo.with_tenant(target.id, fn ->
             with {:ok, group} <- Root.ensure_site_admin_group(repo),
                  {:ok, _} <- Store.lock_group(repo, group.id),
                  {:ok, principal} <- Store.fetch_principal_for_update(repo, uid),
                  :ok <- Store.ensure_active_human(principal),
                  {:ok, _} <- Store.insert_membership(repo, group.id, principal.uid),
                  {:ok, _} <- Grants.upsert_console_admin_grants(repo, group),
                  do: {:ok, group}
           end),
         {:ok, write} <-
           AppConfigure.put_global_by_key_in_tx(repo, @privileged_key, target.id),
         :ok <-
           Repo.with_tenant(privileged_id, fn -> Root.delete_site_admin_group_in_tx(repo) end) do
      {:ok, {target, write}}
    else
      false -> {:error, :tenant_not_active}
      {:error, {:built_in_group_conflict, "siteadmin"}} -> {:error, :group_name_taken}
      error -> error
    end
  end

  @doc false
  def publish_site_administration({_tenant, write}) do
    {:ok, _value} = AppConfigure.cache_committed_write(write)
    :ok
  end

  @doc false
  def lock_administration(repo) do
    case AppConfigure.lock_global_by_key_in_tx(repo, @privileged_key) do
      :error -> {:error, :privileged_tenant_missing}
      result -> result
    end
  end

  defp lock_tenant(id), do: lock_tenant_in_tx(Repo, id)

  @doc """
  Locks one tenant row in the caller's transaction.

  The mode is `:update` (the default), `:share`, or `:key_share`.
  """
  @spec lock_tenant_in_tx(module(), String.t(), :update | :share | :key_share) ::
          {:ok, Tenant.t()} | {:error, term()}
  def lock_tenant_in_tx(_repo, id, mode \\ :update) do
    case Tenant
         |> Ash.Query.filter(id == ^id)
         |> Ash.Query.lock(row_lock(mode))
         |> Ankole.Ash.read_one() do
      {:ok, nil} -> {:error, :not_found}
      result -> result
    end
  end

  defp row_lock(:update), do: :for_update
  defp row_lock(:share), do: "FOR SHARE"
  defp row_lock(:key_share), do: "FOR KEY SHARE"

  defp not_deleting(%Tenant{deleting_at: nil}), do: :ok
  defp not_deleting(_), do: {:error, :tenant_deleting}
  defp not_privileged(%Tenant{id: id}, id), do: {:error, :privileged_tenant_protected}
  defp not_privileged(_, _), do: :ok
end
