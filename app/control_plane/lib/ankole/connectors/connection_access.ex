defmodule Ankole.Connectors.ConnectionAccess do
  @moduledoc """
  Shared connection-level authorization (`members` vs. `restricted`) across
  database and SaaS/API connectors.
  """
  alias Ankole.Principals.ServiceAccounts

  @action "query"
  @access_description "Connection access chosen in the connection settings"

  def resource(%{id: id}), do: "connector_connection:" <> id

  def put_in_tx(_config, nil), do: :ok

  def put_in_tx(config, access) when is_map(access) do
    with {:ok, desired} <- desired_owners(access) do
      existing = grants(config)
      stale = Enum.reject(existing, &(owner(&1) in desired))
      missing = desired -- Enum.map(existing, &owner/1)

      with :ok <- each(stale, &Ankole.AuthZ.Grants.delete_permission_grant(&1.id)) do
        each(missing, fn owner ->
          Ankole.AuthZ.Grants.upsert_permission_grant(
            Map.merge(owner, %{
              resource_pattern: resource(config),
              action: @action,
              condition: "true",
              description: @access_description,
              metadata: %{}
            })
          )
        end)
      end
    end
  end

  def put_in_tx(_config, _invalid), do: {:error, :invalid_connection_access}

  def authorize(%{uid: uid, type: type}, %{id: id} = config) when is_binary(id) do
    mode = Map.get(config.public_metadata || %{}, "access_mode")
    existing_grants = if mode == "members", do: nil, else: grants(config)

    cond do
      existing_grants == [] and mode != "restricted" and not database_config?(config) ->
        :ok

      (mode == "members" or members_mode?(existing_grants || [])) and type == :system and
          ServiceAccounts.applet_service_uid?(uid) ->
        :ok

      Ankole.AuthZ.authorize(uid, resource(config), @action) == :ok ->
        :ok

      true ->
        {:error, :connection_forbidden}
    end
  end

  def authorize(_principal, %{id: nil}), do: :ok

  def project(%{id: nil}), do: nil

  def project(config) do
    mode = Map.get(config.public_metadata || %{}, "access_mode")
    existing_grants = grants(config)

    cond do
      existing_grants == [] and mode != "restricted" and not database_config?(config) ->
        nil

      mode == "members" or members_mode?(existing_grants) ->
        %{"mode" => "members"}

      true ->
        %{
          "mode" => "restricted",
          "group_ids" => existing_grants |> Enum.map(& &1.group_id) |> Enum.reject(&is_nil/1),
          "principal_uids" =>
            existing_grants |> Enum.map(& &1.principal_uid) |> Enum.reject(&is_nil/1)
        }
    end
  end

  def grants(%{id: id}) when is_binary(id) do
    Ankole.AuthZ.list_grants!(
      query: [filter: [resource_pattern: resource(%{id: id}), action: @action]]
    )
  end

  def grants(_config), do: []

  defp database_config?(%{plugin_id: plugin_id}) do
    case Ankole.Connectors.Registry.adapter(plugin_id) do
      {:ok, module} -> Ankole.Connectors.Databases.database?(module)
      _ -> false
    end
  end

  defp members_mode?(grants) do
    case Ankole.AuthZ.get_principal_group("all_humans") do
      {:ok, %{id: humans}} when is_binary(humans) ->
        Enum.any?(grants, &(&1.group_id == humans))

      _ ->
        false
    end
  end

  defp desired_owners(%{"mode" => "members"}) do
    with {:ok, humans} <- Ankole.AuthZ.Root.ensure_all_humans_group(),
         {:ok, agents} <- Ankole.AuthZ.Root.ensure_all_agents_group(),
         do: {:ok, [%{group_id: humans.id}, %{group_id: agents.id}]}
  end

  defp desired_owners(%{"mode" => "restricted"} = access) do
    groups = access["group_ids"] || []
    principals = access["principal_uids"] || []

    if Enum.all?(groups ++ principals, &(is_binary(&1) and &1 != "")),
      do:
        {:ok,
         Enum.map(Enum.uniq(groups), &%{group_id: &1}) ++
           Enum.map(Enum.uniq(principals), &%{principal_uid: &1})},
      else: {:error, :invalid_connection_access}
  end

  defp desired_owners(_), do: {:error, :invalid_connection_access}

  defp owner(%{group_id: id}) when is_binary(id), do: %{group_id: id}
  defp owner(%{principal_uid: uid}), do: %{principal_uid: uid}

  defp each(items, fun) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case fun.(item) do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end
end
