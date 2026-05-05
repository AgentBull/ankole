defmodule BullXAccounts.AuthZ.Bootstrap do
  @moduledoc false

  use Task

  require Logger

  alias BullX.Repo
  alias BullXAccounts.AuthZ
  alias BullXAccounts.PermissionGrant
  alias BullXAccounts.UserGroup

  import Ecto.Query

  def start_link(_opts), do: Task.start_link(__MODULE__, :run, [])

  def child_spec(opts) do
    opts
    |> super()
    |> Map.put(:restart, :transient)
  end

  def run do
    case authz_tables_ready?() do
      true ->
        ensure_admin_group()

      false ->
        Logger.warning("BullXAccounts.AuthZ bootstrap skipped because AuthZ tables do not exist")
    end
  end

  defp ensure_admin_group do
    case AuthZ.ensure_built_in_admin_group() do
      {:ok, group, :created} ->
        Logger.info("BullXAccounts.AuthZ bootstrap created built-in admin group")
        ensure_admin_web_console_grant(group)

      {:ok, group, :existing} ->
        ensure_admin_web_console_grant(group)

      {:error, {:conflicting_admin_group, group}} ->
        log_conflicting_admin_group(group)

      {:error, changeset} ->
        Logger.warning(
          "BullXAccounts.AuthZ bootstrap failed to create admin group: #{inspect(changeset.errors)}"
        )
    end
  end

  defp ensure_admin_web_console_grant(%UserGroup{} = group) do
    case Repo.all(admin_web_console_grant_query(group.id)) do
      [] ->
        create_admin_web_console_grant(group)

      [%PermissionGrant{condition: "true"} | duplicates] ->
        delete_duplicate_admin_web_console_grants(duplicates)
        :ok

      [%PermissionGrant{} = grant | duplicates] ->
        delete_duplicate_admin_web_console_grants(duplicates)
        update_admin_web_console_grant(grant)
    end
  end

  defp admin_web_console_grant_query(group_id) do
    from grant in PermissionGrant,
      where:
        grant.group_id == ^group_id and grant.resource_pattern == "web_console:*" and
          grant.action == "write",
      order_by: [asc: grant.inserted_at, asc: grant.id]
  end

  defp delete_duplicate_admin_web_console_grants([]), do: :ok

  defp delete_duplicate_admin_web_console_grants(duplicates) do
    Enum.each(duplicates, fn grant ->
      :ok = AuthZ.delete_permission_grant(grant)
    end)

    Logger.info(
      "BullXAccounts.AuthZ bootstrap removed duplicate admin web_console:*:write grants"
    )
  end

  defp create_admin_web_console_grant(%UserGroup{} = group) do
    case AuthZ.create_permission_grant(%{
           group_id: group.id,
           resource_pattern: "web_console:*",
           action: "write",
           condition: "true",
           description: "Built-in Web Console access for administrators.",
           metadata: %{"managed_by" => "bullx.authz.bootstrap"}
         }) do
      {:ok, _grant} ->
        Logger.info("BullXAccounts.AuthZ bootstrap granted web_console:*:write to admin group")

      {:error, changeset} ->
        Logger.warning(
          "BullXAccounts.AuthZ bootstrap failed to create admin grant: #{inspect(changeset.errors)}"
        )
    end
  end

  defp update_admin_web_console_grant(%PermissionGrant{} = grant) do
    case AuthZ.update_permission_grant(grant, %{
           condition: "true",
           description: "Built-in Web Console access for administrators.",
           metadata: Map.put(grant.metadata || %{}, "managed_by", "bullx.authz.bootstrap")
         }) do
      {:ok, _grant} ->
        Logger.info("BullXAccounts.AuthZ bootstrap repaired admin web_console:*:write grant")

      {:error, changeset} ->
        Logger.warning(
          "BullXAccounts.AuthZ bootstrap failed to repair admin grant: #{inspect(changeset.errors)}"
        )
    end
  end

  defp log_conflicting_admin_group(%UserGroup{} = group) do
    Logger.warning(
      "BullXAccounts.AuthZ bootstrap found conflicting admin group: #{inspect(Map.take(group, [:id, :type, :built_in]))}"
    )
  end

  defp authz_tables_ready? do
    query = """
    SELECT
      EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = current_schema()
          AND table_name = 'user_groups'
      ),
      EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = current_schema()
          AND table_name = 'permission_grants'
      )
    """

    case Ecto.Adapters.SQL.query(Repo, query, []) do
      {:ok, %{rows: [[user_groups, permission_grants]]}} -> user_groups and permission_grants
      {:error, reason} -> log_table_check_error(reason)
    end
  end

  defp log_table_check_error(reason) do
    Logger.warning("BullXAccounts.AuthZ bootstrap table check failed: #{inspect(reason)}")
    false
  end
end
