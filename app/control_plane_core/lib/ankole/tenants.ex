defmodule Ankole.Tenants do
  @moduledoc """
  Durable tenant lifecycle and the single site-administration assignment.

  This module is the Tenants domain. Each lifecycle operation locks the site
  administration and the tenant row in a top-level transaction
  (`Repo.transact_top_level/2`), and `Ankole.Tenants.Tenant` exposes generic
  actions for the `/api/v2/site` routes. The `_in_tx` functions run the same
  steps in the caller's transaction.
  """
  use Ankole.Ash.Domain, extensions: [AshJsonApi.Domain]

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

  # The site administration API at `/api/v2/site` (`AnkoleWeb.JSONAPI.SiteRouter`).
  json_api do
    authorize?(false)
    log_errors?(true)
    show_raised_errors?(false)

    routes do
      base_route "/tenants", Tenant do
        index(:list, name: "list_tenants", derive_sort?: false)
        post(:create, name: "create_tenant")
        patch(:change_profile, route: "/:id", name: "update_tenant")
        delete(:begin_delete, route: "/:id", name: "delete_tenant")
        post(:suspend, route: "/:id/suspension", name: "suspend_tenant")
        delete(:resume, route: "/:id/suspension", name: "resume_tenant")
        route(:get, "/brain-packs", :brain_packs, name: "list_tenant_brain_packs")
      end

      base_route "/privileged-tenant", Tenant do
        get(:privileged, route: "/", name: "get_privileged_tenant", derive_sort?: false)

        patch(:transfer_site_administration,
          route: "/",
          name: "transfer_site_administration"
        )
      end
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
    with {:ok, id} <- privileged_id(),
         {:ok, %Tenant{} = tenant} <- get_tenant(id) do
      {:ok, tenant}
    else
      _missing -> {:error, :privileged_tenant_missing}
    end
  end

  @doc false
  def privileged_id, do: AppConfigure.get_global_by_key_in_tx(@privileged_key)

  def list, do: Ankole.Ash.read!(Ash.Query.for_read(Tenant, :list))

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
  def check_work_admission_in_tx(id) do
    case Tenant
         |> Ash.Query.filter(id == ^id)
         |> Ash.Query.lock("FOR SHARE")
         |> Ankole.Ash.read_one() do
      {:ok, %Tenant{} = tenant} -> check_work_admission(tenant)
      {:ok, nil} -> {:error, :tenant_suspended}
      {:error, _reason} = error -> error
    end
  end

  def create(attrs) when is_map(attrs),
    do: Repo.transact_top_level(fn -> create_in_tx(attrs) end)

  @doc false
  def create_in_tx(attrs) do
    slug = Ankole.Attrs.get(attrs, :slug)
    display_name = Ankole.Attrs.get(attrs, :display_name)
    brain_packs = Ankole.Attrs.get(attrs, :brain_packs, []) || []

    with {:ok, tenant} <-
           Ankole.Ash.create(Tenant, :create_in_tx, %{slug: slug, display_name: display_name}) do
      Repo.with_tenant(tenant.id, fn ->
        with :ok <- ensure_scaffold_in_tx(tenant),
             :ok <- Ankole.Pod.Access.initialize_space(),
             {:ok, _} <- Ankole.Brain.SchemaPacks.install_packs_in_tx(brain_packs) do
          {:ok, tenant}
        end
      end)
    end
  end

  def ensure_scaffold(%Tenant{} = tenant),
    do: Repo.transact_top_level(fn -> ensure_scaffold_in_tx(tenant) end)

  @doc false
  def ensure_scaffold_in_tx(%Tenant{} = tenant) do
    Repo.with_tenant(tenant.id, fn ->
      with {:ok, _} <- lock_administration(),
           {:ok, _} <- Root.ensure_all_humans_group(),
           {:ok, _} <- Principals.ensure_system_principal_in_tx(),
           :ok <- ensure_privileged_group(tenant) do
        :ok
      end
    end)
  end

  defp ensure_privileged_group(tenant) do
    case privileged() do
      {:ok, %Tenant{id: id}} when id == tenant.id ->
        with {:ok, group} <- Root.ensure_site_admin_group(),
             {:ok, _} <- Grants.upsert_console_admin_grants(group),
             do: :ok

      {:ok, _} ->
        :ok

      error ->
        error
    end
  end

  def update(%Tenant{id: id}, attrs),
    do: Repo.transact_top_level(fn -> change_profile_in_tx(id, attrs) end)

  def suspend(%Tenant{id: id}),
    do: Repo.transact_top_level(fn -> suspend_in_tx(id) end)

  def resume(%Tenant{id: id}),
    do: Repo.transact_top_level(fn -> resume_in_tx(id) end)

  def delete(%Tenant{id: id}),
    do: Repo.transact_top_level(fn -> begin_delete_in_tx(id) end)

  @doc false
  def change_profile_in_tx(id, attrs) do
    with {:ok, _} <- lock_administration(),
         {:ok, tenant} <- lock_tenant(id),
         :ok <- not_deleting(tenant) do
      Ankole.Ash.update(tenant, :profile_in_tx, Map.take(attrs, [:slug, :display_name]))
    end
  end

  @doc false
  def suspend_in_tx(id) do
    with {:ok, privileged_id} <- lock_administration(),
         {:ok, tenant} <- lock_tenant(id),
         :ok <- not_deleting(tenant),
         :ok <- not_privileged(tenant, privileged_id) do
      Ankole.Ash.update(tenant, :suspend_in_tx, %{})
    end
  end

  @doc false
  def resume_in_tx(id) do
    with {:ok, _} <- lock_administration(),
         {:ok, tenant} <- lock_tenant(id),
         :ok <- not_deleting(tenant) do
      Ankole.Ash.update(tenant, :resume_in_tx, %{})
    end
  end

  @doc false
  def begin_delete_in_tx(id) do
    with {:ok, privileged_id} <- lock_administration(),
         {:ok, tenant} <- lock_tenant(id),
         :ok <- not_privileged(tenant, privileged_id),
         {:ok, tenant} <- Ankole.Ash.update(tenant, :begin_delete_in_tx, %{}),
         {:ok, _} <- Ankole.Tenants.Jobs.Delete.new(%{tenant_id: tenant.id}) |> Oban.insert() do
      {:ok, tenant}
    end
  end

  def transfer_site_administration(%Tenant{id: id}, uid) do
    Repo.transact_top_level(
      fn -> transfer_site_administration_in_tx(id, uid) end,
      after_commit: &publish_site_administration/1
    )
  end

  @doc false
  def transfer_site_administration_in_tx(id, uid) do
    with {:ok, privileged_id} <- lock_administration(),
         {:ok, target} <- lock_tenant(id),
         :ok <- not_privileged(target, privileged_id),
         true <- accepting_work?(target),
         {:ok, _} <-
           Repo.with_tenant(target.id, fn ->
             with {:ok, group} <- Root.ensure_site_admin_group(),
                  {:ok, _} <- Store.lock_group(group.id),
                  {:ok, principal} <- Store.fetch_principal_for_update(uid),
                  :ok <- Store.ensure_active_human(principal),
                  {:ok, _} <- Store.insert_membership(group.id, principal.uid),
                  {:ok, _} <- Grants.upsert_console_admin_grants(group),
                  do: {:ok, group}
           end),
         {:ok, _write} <-
           AppConfigure.put_global_by_key_in_tx(@privileged_key, target.id),
         :ok <-
           Repo.with_tenant(privileged_id, fn -> Root.delete_site_admin_group_in_tx() end) do
      {:ok, target}
    else
      false -> {:error, :tenant_not_active}
      {:error, {:built_in_group_conflict, "siteadmin"}} -> {:error, :group_name_taken}
      error -> error
    end
  end

  @doc false
  def publish_site_administration(%Tenant{id: id}) do
    {:ok, _value} = AppConfigure.cache_committed_write({id, "global", @privileged_key})
    :ok
  end

  @doc false
  def lock_administration do
    case AppConfigure.lock_global_by_key_in_tx(@privileged_key) do
      :error -> {:error, :privileged_tenant_missing}
      result -> result
    end
  end

  defp lock_tenant(id), do: lock_tenant_in_tx(id)

  @doc """
  Locks one tenant row in the caller's transaction.

  The mode is `:update` (the default), `:share`, or `:key_share`.
  """
  @spec lock_tenant_in_tx(String.t(), :update | :share | :key_share) ::
          {:ok, Tenant.t()} | {:error, term()}
  def lock_tenant_in_tx(id, mode \\ :update) do
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

  @doc """
  Gives the v2 error of a lifecycle rejection for `Ankole.Errors.wrap/2`: a
  missing tenant is not found, and a refused operation conflicts with the state
  of the tenant or of the site administration.
  """
  def rejection(:not_found), do: Ankole.Errors.Invalid.NotFound.exception(resource: Tenant)

  def rejection(reason) when is_atom(reason),
    do: {:conflict, "The tenant operation was refused", []}

  def rejection(_reason), do: nil

  defp not_deleting(%Tenant{deleting_at: nil}), do: :ok
  defp not_deleting(_), do: {:error, :tenant_deleting}
  defp not_privileged(%Tenant{id: id}, id), do: {:error, :privileged_tenant_protected}
  defp not_privileged(_, _), do: :ok
end
