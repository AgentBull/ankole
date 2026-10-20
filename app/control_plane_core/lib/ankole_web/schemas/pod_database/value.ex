defmodule AnkoleWeb.Schemas.PodDatabase.Value do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(
    %Schema{
      nullable: true,
      oneOf: [
        %Schema{type: :string},
        %Schema{type: :number},
        %Schema{type: :boolean},
        %Schema{type: :array, items: %Schema{}},
        %Schema{type: :object, additionalProperties: true}
      ]
    },
    struct?: false
  )
end
