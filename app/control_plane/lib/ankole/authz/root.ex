defmodule Ankole.AuthZ.Root do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Ecto.Adapters.SQL
  alias Ecto.Changeset
  alias Ankole.AuthZ.Grants
  alias Ankole.AuthZ.Group
  alias Ankole.AuthZ.Membership
  alias Ankole.AuthZ.Store
  alias Ankole.Repo

  require Logger

  @admin_group_name "admin"
  @all_humans_group_name "all_humans"
  @all_humans_condition ~s(principal.type == "human" && principal.status == "active")

  def admin_group_name, do: @admin_group_name

  def root_initialized? do
    storage_ready?() and built_in_admin_group_ready?(Repo) and
      built_in_all_humans_group_ready?(Repo)
  end

  def ensure_console_admin_grants do
    case Repo.transact(fn repo ->
           with {:ok, built_ins} <- ensure_builtin_groups(repo) do
             case Grants.console_admin_grants_ready?(repo, built_ins.admin_group.id) do
               true ->
                 {:ok, :ready}

               false ->
                 with {:ok, _grants} <-
                        Grants.upsert_console_admin_grants(repo, built_ins.admin_group) do
                   {:ok, :created}
                 end
             end
           end
         end) do
      {:ok, _status} -> :ok
      {:error, _reason} = error -> error
    end
  end

  def ensure_root_init_open do
    ensure_root_init_open(Repo)
  end

  def root_init_admin(principal_uid) do
    Repo.transact(fn repo ->
      with {:ok, principal} <- Store.fetch_principal_for_update(repo, principal_uid),
           :ok <- Store.ensure_active_human(principal),
           {:ok, built_ins} <- ensure_builtin_groups(repo),
           {:ok, admin_group} <- Store.lock_group(repo, built_ins.admin_group.id),
           :ok <- ensure_root_init_open(repo, admin_group.id),
           {:ok, membership} <- Store.insert_membership(repo, admin_group.id, principal.uid),
           {:ok, console_grants} <- Grants.upsert_console_admin_grants(repo, admin_group) do
        {:ok,
         %{
           admin_group: admin_group,
           all_humans_group: built_ins.all_humans_group,
           console_grants: console_grants,
           membership: membership
         }}
      end
    end)
  end

  def ensure_builtin_groups(repo) do
    with {:ok, admin_group} <-
           upsert_builtin_group(repo, %{
             name: @admin_group_name,
             display_name: "Administrators",
             kind: :static,
             built_in: true,
             computed_condition: nil,
             description: "Root operators for this Ankole installation",
             metadata: %{}
           }),
         {:ok, all_humans_group} <-
           upsert_builtin_group(repo, %{
             name: @all_humans_group_name,
             display_name: "All Humans",
             kind: :computed,
             built_in: true,
             computed_condition: @all_humans_condition,
             description: "Computed group for active human Principals",
             metadata: %{}
           }) do
      {:ok, %{admin_group: admin_group, all_humans_group: all_humans_group}}
    end
  end

  def ensure_root_init_open(repo) do
    case fetch_built_in_admin_group_by_name(repo) do
      %Group{} = admin_group -> ensure_root_init_open(repo, admin_group.id)
      nil -> :ok
    end
  end

  def ensure_root_init_open(repo, admin_group_id) do
    case admin_member_exists?(repo, admin_group_id) do
      true -> {:error, :root_init_closed}
      false -> :ok
    end
  end

  defp upsert_builtin_group(repo, attrs) do
    case Store.fetch_group_by_name(repo, attrs.name) do
      %Group{} = group ->
        case builtin_shape_matches?(group, attrs) do
          true -> {:ok, group}
          false -> {:error, {:built_in_group_conflict, attrs.name}}
        end

      nil ->
        create_builtin_group(repo, attrs)
    end
  end

  defp create_builtin_group(repo, attrs) do
    %Group{}
    |> Group.changeset(attrs)
    |> repo.insert()
    |> case do
      {:ok, group} -> {:ok, group}
      {:error, %Changeset{} = changeset} -> built_in_group_insert_error(repo, changeset, attrs)
    end
  end

  defp builtin_shape_matches?(%Group{} = group, attrs) do
    group.kind == attrs.kind and group.built_in == true and
      group.computed_condition == attrs.computed_condition
  end

  defp built_in_group_insert_error(repo, %Changeset{} = changeset, attrs) do
    case unique_conflict?(changeset, :name) do
      true -> upsert_builtin_group(repo, attrs)
      false -> {:error, changeset}
    end
  end

  defp unique_conflict?(%Changeset{} = changeset, field) do
    Enum.any?(changeset.errors, fn
      {^field, {_message, opts}} -> match?(%{constraint: :unique}, Map.new(opts))
      {_field, _error} -> false
    end)
  end

  defp storage_ready? do
    query = """
    SELECT
      EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = current_schema() AND table_name = 'principal_groups'
      ),
      EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = current_schema() AND table_name = 'principal_group_memberships'
      ),
      EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = current_schema() AND table_name = 'permission_grants'
      ),
      EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = current_schema() AND table_name = 'principals'
      )
    """

    case SQL.query(Repo, query, []) do
      {:ok, %{rows: [row]}} ->
        Enum.all?(row)

      {:error, reason} ->
        Logger.debug("AuthZ root_initialized table check failed: #{inspect(reason)}")
        false
    end
  end

  defp built_in_admin_group_ready?(repo) do
    repo.exists?(
      from group in Group,
        where:
          group.name == ^@admin_group_name and group.built_in == true and group.kind == :static and
            is_nil(group.computed_condition)
    )
  end

  defp built_in_all_humans_group_ready?(repo) do
    repo.exists?(
      from group in Group,
        where:
          group.name == ^@all_humans_group_name and group.built_in == true and
            group.kind == :computed and group.computed_condition == ^@all_humans_condition
    )
  end

  defp fetch_built_in_admin_group_by_name(repo) do
    repo.one(
      from group in Group,
        where: group.name == ^@admin_group_name and group.built_in == true
    )
  end

  defp admin_member_exists?(repo, admin_group_id) do
    repo.exists?(from membership in Membership, where: membership.group_id == ^admin_group_id)
  end
end
