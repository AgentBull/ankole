defmodule Ankole.AgentWorkers.ProviderKind.CredentialFields do
  @moduledoc "The named credential inputs of a Worker provider kind."
  use Ash.Type.NewType, subtype_of: :map
  use AshJsonApi.Type

  @impl AshJsonApi.Type
  def json_schema(_constraints) do
    %OpenApiSpex.Schema{
      type: :object,
      additionalProperties: %OpenApiSpex.Schema{
        type: :object,
        properties: %{required: %OpenApiSpex.Schema{type: :boolean}},
        required: [:required]
      }
    }
  end

  @impl AshJsonApi.Type
  def json_write_schema(_constraints),
    do: %{
      "type" => "object",
      "additionalProperties" => %{
        "type" => "object",
        "properties" => %{"required" => %{"type" => "boolean"}},
        "required" => ["required"]
      }
    }
end
