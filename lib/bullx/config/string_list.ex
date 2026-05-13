defmodule BullX.Config.StringList do
  @moduledoc """
  Skogsra type for runtime settings stored as a list of strings.

  PostgreSQL and OS environment sources store configuration as strings, so this
  type accepts a JSON array string at those boundaries. Application config may
  provide the native list directly.
  """

  use Skogsra.Type

  @impl Skogsra.Type
  def cast(values) when is_list(values) do
    case Enum.all?(values, &is_binary/1) do
      true -> {:ok, values}
      false -> :error
    end
  end

  def cast(value) when is_binary(value) do
    with {:ok, values} <- Jason.decode(value),
         true <- Enum.all?(values, &is_binary/1) do
      {:ok, values}
    else
      _other -> :error
    end
  end

  def cast(_value), do: :error
end
