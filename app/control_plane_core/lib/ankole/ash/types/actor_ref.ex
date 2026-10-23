defmodule Ankole.Ash.Types.ActorRef do
  @moduledoc "Uses the Principal owner's tenant-qualified attribution codec."
  use Ash.Type

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

  @doc "Gives the OpenAPI schema of the JSON:API value: the tenant and the UID."
  def json_schema(_constraints) do
    %{
      "type" => "object",
      "properties" => %{
        "tenant_id" => %{"type" => "string", "format" => "uuid"},
        "uid" => %{"type" => "string"}
      },
      "required" => ["tenant_id", "uid"],
      "additionalProperties" => false
    }
  end
end
