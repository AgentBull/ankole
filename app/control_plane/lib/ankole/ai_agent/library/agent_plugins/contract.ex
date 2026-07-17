defmodule Ankole.AIAgent.Library.AgentPlugins.Contract do
  @moduledoc false

  @identifier ~r/\A[a-z][a-z0-9_-]{0,63}\z/
  @reasoning_efforts ~w(minimal low medium high xhigh)
  @mount_access ~w(read_only read_write)

  @spec reasoning_efforts() :: [String.t()]
  def reasoning_efforts, do: @reasoning_efforts

  @spec validate_identifier(term()) :: :ok | {:error, :invalid_identifier}
  def validate_identifier(value) when is_binary(value) do
    if Regex.match?(@identifier, value), do: :ok, else: {:error, :invalid_identifier}
  end

  def validate_identifier(_value), do: {:error, :invalid_identifier}

  @spec validate_workspace_mounts(term()) :: :ok | {:error, term()}
  def validate_workspace_mounts(mounts)
      when is_list(mounts) and mounts != [] and length(mounts) <= 16 do
    with :ok <- unique_by(mounts, &map_value(&1, "id"), :duplicate_workspace_mount_id) do
      mounts
      |> Enum.with_index()
      |> Enum.reduce_while(:ok, fn
        {%{} = mount, index}, :ok ->
          case validate_workspace_mount(mount, index) do
            :ok -> {:cont, :ok}
            {:error, _reason} = error -> {:halt, error}
          end

        {_mount, index}, :ok ->
          {:halt, {:error, {:invalid_workspace_mount, index}}}
      end)
    end
  end

  def validate_workspace_mounts(_mounts), do: {:error, :invalid_workspace_mounts}

  defp validate_workspace_mount(mount, index) do
    keys = mount |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()
    id = map_value(mount, "id")
    source = map_value(mount, "source")
    access = map_value(mount, "access")
    expanded_source = if is_binary(source), do: Path.expand(source), else: nil

    cond do
      keys != ~w(access id source) ->
        {:error, {:invalid_workspace_mount_keys, index}}

      validate_identifier(id) != :ok ->
        {:error, {:invalid_workspace_mount_id, index}}

      not is_binary(source) or expanded_source != source or
          not String.starts_with?(expanded_source, "/workspace/user-files/") ->
        {:error, {:invalid_workspace_mount_source, index}}

      access not in @mount_access ->
        {:error, {:invalid_workspace_mount_access, index}}

      true ->
        :ok
    end
  end

  defp unique_by(items, mapper, reason) do
    values = Enum.map(items, mapper)

    cond do
      Enum.any?(values, &is_nil/1) -> {:error, reason}
      Enum.uniq(values) != values -> {:error, reason}
      true -> :ok
    end
  end

  defp map_value(%{} = map, "id"), do: Map.get(map, "id", Map.get(map, :id))

  defp map_value(%{} = map, "source"), do: Map.get(map, "source", Map.get(map, :source))
  defp map_value(%{} = map, "access"), do: Map.get(map, "access", Map.get(map, :access))
  defp map_value(_value, _key), do: nil
end
