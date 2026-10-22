defmodule Ankole.Ash.Types.State do
  @moduledoc "Keeps state values canonical when existing Ecto callers cast resource rows."
  use Ash.Type.NewType, subtype_of: :atom

  @impl true
  def ecto_type, do: Ankole.Ash.Ecto.StateEnum
end

defmodule Ankole.Ash.Ecto.StateEnum do
  @moduledoc false
  use Ecto.ParameterizedType

  @impl true
  def init(opts), do: Ecto.Enum.init(values: Keyword.fetch!(opts, :one_of))
  @impl true
  def type(params), do: Ecto.Enum.type(enum_params(params))
  @impl true
  def cast(value, params), do: Ecto.Enum.cast(value, enum_params(params))
  @impl true
  def load(value, loader, params), do: Ecto.Enum.load(value, loader, enum_params(params))
  @impl true
  def dump(value, dumper, params), do: Ecto.Enum.dump(value, dumper, enum_params(params))
  @impl true
  def equal?(left, right, params), do: Ecto.Enum.equal?(left, right, enum_params(params))
  @impl true
  def embed_as(format, params), do: Ecto.Enum.embed_as(format, enum_params(params))

  # AshSql passes Ash constraints directly for atomic expression parameters.
  defp enum_params(params) when is_list(params), do: init(params)
  defp enum_params(params) when is_map(params), do: params
end
