defmodule Ankole.Tenants do
  @moduledoc "Durable tenant lifecycle and the single site-administration assignment."
  import Ecto.Query
  alias Ankole.{AppConfigure, Repo}
  alias Ankole.AppConfigure.SiteConfig
  alias Ankole.AuthZ.Grant
  alias Ankole.AuthZ.Group
  alias Ankole.AuthZ.Grants
  alias Ankole.AuthZ.Root
  alias Ankole.AuthZ.Store
  alias Ankole.Principals.Principal
  alias Ankole.Tenants.Tenant

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
    case AppConfigure.get_global_by_key_in_tx(Repo, @privileged_key) do
      {:ok, id} ->
        case Repo.get(Tenant, id) do
          %Tenant{} = tenant -> {:ok, tenant}
          nil -> {:error, :privileged_tenant_missing}
        end

      _ ->
        {:error, :privileged_tenant_missing}
    end
  end

  def list do
    Repo.all(from tenant in Tenant, order_by: [asc: tenant.inserted_at, asc: tenant.id])
  end

  def get(id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Tenant{} = tenant <- Repo.get(Tenant, id),
         do: {:ok, tenant},
         else: (_ -> {:error, :not_found})
  end

  @doc "Finds an exact slug whose tenant accepts new work."
  def active_by_slug(slug) when is_binary(slug) do
    with %Tenant{} = tenant <- Repo.get_by(Tenant, slug: slug),
         true <- accepting_work?(tenant),
         do: {:ok, tenant},
         else: (_ -> {:error, :not_found})
  end

  @doc "Runs a site fan-out without letting one tenant's failure skip another tenant."
  def map_active(fun) when is_function(fun, 0) do
    active =
      Repo.all(
        from tenant in Tenant,
          where: is_nil(tenant.suspended_at) and is_nil(tenant.deleting_at),
          order_by: [asc: tenant.inserted_at, asc: tenant.id]
      )

    map(active, fun)
  end

  @doc "Runs retention work in every tenant, including suspended and deleting tenants."
  def map_all(fun) when is_function(fun, 0), do: map(list(), fun)

  defp map(tenants, fun) do
    Enum.map(tenants, fn tenant ->
      result =
        Repo.with_tenant(tenant.id, fn ->
          try do
            fun.()
          rescue
            error -> {:error, {:exception, Exception.message(error)}}
          catch
            kind, reason -> {:error, {kind, reason}}
          end
        end)

      if match?({:error, _}, result) do
        Ankole.Logging.warning(
          "tenants.site_fanout_failed",
          "Site work failed for one tenant",
          %{tenant_id: tenant.id, reason: inspect(result)}
        )
      end

      {tenant.id, result}
    end)
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

  def create(attrs) do
    Repo.transact(fn repo ->
      with {:ok, tenant} <-
             %Tenant{}
             |> Tenant.changeset(Map.take(attrs, [:slug, :display_name]))
             |> repo.insert() do
        Repo.with_tenant(tenant.id, fn ->
          with :ok <- ensure_scaffold(tenant),
               :ok <- Ankole.Pod.Access.initialize_space(repo),
               {:ok, _} <-
                 Ankole.Brain.SchemaPacks.install_packs(
                   Map.get(attrs, :brain_packs, []),
                   repo: repo
                 ) do
            {:ok, tenant}
          end
        end)
      end
    end)
  end

  def ensure_scaffold(%Tenant{} = tenant) do
    Repo.with_tenant(tenant.id, fn ->
      case Repo.transact(fn repo ->
             with {:ok, _} <- lock_administration(repo),
                  {:ok, _} <- Root.ensure_all_humans_group(repo),
                  {:ok, _} <- ensure_system_principal(repo),
                  :ok <- ensure_privileged_group(repo, tenant) do
               {:ok, :ready}
             end
           end) do
        {:ok, :ready} -> :ok
        error -> error
      end
    end)
  end

  def system_principal do
    case Repo.get_by(Principal, type: :system) do
      %Principal{} = principal -> {:ok, principal}
      nil -> {:error, :system_principal_missing}
    end
  end

  defp ensure_system_principal(repo) do
    case repo.get_by(Principal, type: :system) do
      nil ->
        %Principal{}
        |> Principal.changeset(%{
          uid: Ankole.Kernel.gen_uuid_v7(),
          type: :system,
          status: :active,
          display_name: "System"
        })
        |> repo.insert()

      principal ->
        {:ok, principal}
    end
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

  def update(%Tenant{id: id}, attrs) do
    Repo.transact(fn repo ->
      with {:ok, _} <- lock_administration(repo),
           {:ok, tenant} <- lock_tenant(repo, id),
           :ok <- not_deleting(tenant) do
        tenant
        |> Tenant.changeset(Map.take(attrs, [:slug, :display_name]))
        |> repo.update()
      end
    end)
  end

  def suspend(%Tenant{id: id}) do
    Repo.transact(fn repo ->
      with {:ok, privileged_id} <- lock_administration(repo),
           {:ok, tenant} <- lock_tenant(repo, id),
           :ok <- not_deleting(tenant),
           :ok <- not_privileged(tenant, privileged_id) do
        tenant |> Ecto.Changeset.change(suspended_at: DateTime.utc_now()) |> repo.update()
      end
    end)
  end

  def resume(%Tenant{id: id}) do
    Repo.transact(fn repo ->
      with {:ok, _} <- lock_administration(repo),
           {:ok, tenant} <- lock_tenant(repo, id),
           :ok <- not_deleting(tenant) do
        tenant |> Ecto.Changeset.change(suspended_at: nil) |> repo.update()
      end
    end)
  end

  def delete(%Tenant{id: id}) do
    Repo.transact(fn repo ->
      with {:ok, privileged_id} <- lock_administration(repo),
           {:ok, tenant} <- lock_tenant(repo, id),
           :ok <- not_privileged(tenant, privileged_id),
           {:ok, tenant} <-
             tenant
             |> Ecto.Changeset.change(deleting_at: tenant.deleting_at || DateTime.utc_now())
             |> repo.update(),
           {:ok, _} <- Ankole.Tenants.Jobs.Delete.new(%{tenant_id: tenant.id}) |> Oban.insert() do
        {:ok, tenant}
      end
    end)
  end

  def transfer_site_administration(%Tenant{id: id}, uid) do
    result =
      Repo.transact(fn repo ->
        with {:ok, privileged_id} <- lock_administration(repo),
             {:ok, target} <- lock_tenant(repo, id),
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
               AppConfigure.put_global_by_key_in_tx(repo, @privileged_key, target.id) do
          remove_site_admin_group(repo, privileged_id)

          {:ok, {target, write}}
        else
          false -> {:error, :tenant_not_active}
          {:error, {:built_in_group_conflict, "siteadmin"}} -> {:error, :group_name_taken}
          error -> error
        end
      end)

    committed_tenant(result)
  end

  defp remove_site_admin_group(repo, tenant_id) do
    tenant = repo.get!(Tenant, tenant_id)

    Repo.with_tenant(tenant.id, fn ->
      Ankole.Pod.Pages.lock_tree()

      if group = repo.get_by(Group, name: Root.admin_group_name(), built_in: true) do
        repo.delete_all(from grant in Grant, where: grant.group_id == ^group.id)
        repo.delete!(group)
      end
    end)
  end

  @doc false
  def lock_administration(repo) do
    case repo.one(
           from config in SiteConfig,
             where: config.scope == "global" and config.key == @privileged_key,
             lock: "FOR UPDATE"
         ) do
      nil -> {:error, :privileged_tenant_missing}
      _ -> AppConfigure.get_global_by_key_in_tx(repo, @privileged_key)
    end
  end

  defp lock_tenant(repo, id) do
    case repo.one(from tenant in Tenant, where: tenant.id == ^id, lock: "FOR UPDATE") do
      nil -> {:error, :not_found}
      tenant -> {:ok, tenant}
    end
  end

  defp not_deleting(%Tenant{deleting_at: nil}), do: :ok
  defp not_deleting(_), do: {:error, :tenant_deleting}
  defp not_privileged(%Tenant{id: id}, id), do: {:error, :privileged_tenant_protected}
  defp not_privileged(_, _), do: :ok

  defp committed_tenant({:ok, {tenant, write}}) do
    with {:ok, _} <- AppConfigure.cache_committed_write(write), do: {:ok, tenant}
  end

  defp committed_tenant(error), do: error
end
