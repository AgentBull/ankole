defmodule Ankole.Ash.Types.JSONMap do
  @moduledoc "Uses the durable JSON object contract for Ash attributes."
  use Ash.Type
  use AshJsonApi.Type

  @impl true
  def constraints do
    [allow_datetime?: [type: :boolean, default: false], max_bytes: [type: :pos_integer]]
  end

  @impl true
  def cast_atomic(value, constraints) do
    if Ash.Expr.expr?(value), do: {:atomic, value}, else: cast_input(value, constraints)
  end

  @impl true
  def storage_type(_constraints), do: :map
  @impl true
  def cast_input(nil, _constraints), do: {:ok, nil}
  def cast_input(value, constraints), do: normalize(value, constraints)
  @impl true
  def cast_stored(nil, _constraints), do: {:ok, nil}
  def cast_stored(value, constraints), do: normalize(value, constraints)
  @impl true
  def dump_to_native(nil, _constraints), do: {:ok, nil}
  def dump_to_native(value, constraints), do: normalize(value, constraints)

  defp normalize(value, constraints) do
    case Ankole.Ecto.JSONPayload.normalize_map(value,
           allow_datetime: Keyword.get(constraints, :allow_datetime?, false)
         ) do
      {:ok, map} ->
        validate_size(map, constraints)

      {:error, reason} ->
        {:error,
         message:
           "must be JSON-serializable object: #{Ankole.Ecto.JSONPayload.reason_text(reason)}"}
    end
  end

  defp validate_size(map, constraints) do
    case Keyword.get(constraints, :max_bytes) do
      nil ->
        {:ok, map}

      maximum ->
        {:ok, encoded} = Torque.encode(map)
        if byte_size(encoded) <= maximum, do: {:ok, map}, else: {:error, message: "is too large"}
    end
  end

  @impl AshJsonApi.Type
  def json_schema(_constraints),
    do: %OpenApiSpex.Schema{type: :object, additionalProperties: true}
end
