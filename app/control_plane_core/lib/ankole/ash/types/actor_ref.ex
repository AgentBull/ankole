defmodule Ankole.Ash.Types.ActorRef do
  @moduledoc "Uses the Principal owner's tenant-qualified attribution codec."
  use Ash.Type
  use AshJsonApi.Type

  @impl true
  def storage_type(_constraints), do: :string
  @impl true
  def ecto_type, do: Ankole.Ecto.ActorRef
  @impl true
  def cast_input(nil, _constraints), do: {:ok, nil}
  def cast_input(value, _constraints), do: Ankole.Ecto.ActorRef.cast(value)
  @impl true
  def cast_stored(nil, _constraints), do: {:ok, nil}
  def cast_stored(value, _constraints), do: Ankole.Ecto.ActorRef.load(value)
  @impl true
  def dump_to_native(nil, _constraints), do: {:ok, nil}
  def dump_to_native(value, _constraints), do: Ankole.Ecto.ActorRef.dump(value)

  @impl AshJsonApi.Type
  def json_schema(_constraints) do
    %OpenApiSpex.Schema{
      type: :object,
      properties: %{
        tenant_id: %OpenApiSpex.Schema{type: :string},
        uid: %OpenApiSpex.Schema{type: :string}
      },
      required: [:tenant_id, :uid],
      additionalProperties: false
    }
  end
end
