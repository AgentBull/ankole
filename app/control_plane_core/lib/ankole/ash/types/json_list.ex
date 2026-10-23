defmodule Ankole.Ash.Types.JSONList do
  @moduledoc "Uses the durable JSON array contract for Ash attributes."
  use Ash.Type
  use AshJsonApi.Type

  @impl true
  def cast_atomic(value, constraints) do
    if Ash.Expr.expr?(value), do: {:atomic, value}, else: cast_input(value, constraints)
  end

  @impl true
  def storage_type(_constraints), do: :map
  @impl true
  def cast_input(nil, _constraints), do: {:ok, nil}
  def cast_input(value, _constraints), do: normalize(value)
  @impl true
  def cast_stored(nil, _constraints), do: {:ok, nil}
  def cast_stored(value, _constraints), do: normalize(value)
  @impl true
  def dump_to_native(nil, _constraints), do: {:ok, nil}
  def dump_to_native(value, _constraints), do: normalize(value)

  defp normalize(value) do
    case Ankole.Ecto.JSONPayload.normalize_list(value) do
      {:ok, list} ->
        {:ok, list}

      {:error, reason} ->
        {:error,
         message: "must be JSON-serializable list: #{Ankole.Ecto.JSONPayload.reason_text(reason)}"}
    end
  end

  # The OpenAPI document reads a schema struct; the request validation reads
  # a JSON Schema map.
  @impl AshJsonApi.Type
  def json_schema(_constraints),
    do: %OpenApiSpex.Schema{type: :array, items: %OpenApiSpex.Schema{}}

  @impl AshJsonApi.Type
  def json_write_schema(_constraints), do: %{"type" => "array", "items" => %{}}
end
