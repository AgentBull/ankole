defmodule AnkoleWeb.Schemas.PodModels do
  @moduledoc false

  defmodule Profile do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodModelProfile",
        type: :object,
        properties: %{
          name: %OpenApiSpex.Schema{type: :string},
          description: %OpenApiSpex.Schema{type: :string}
        },
        required: [:name, :description],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule Catalog do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodModelProfiles",
        type: :object,
        properties: %{
          profiles: %OpenApiSpex.Schema{type: :array, items: AnkoleWeb.Schemas.PodModels.Profile}
        },
        required: [:profiles],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule Choice do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodModelChoice",
        type: :object,
        properties: %{profile: %OpenApiSpex.Schema{type: :string, nullable: true}},
        required: [:profile],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule Selection do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodModelSelection",
        type: :object,
        properties: %{
          profile: %OpenApiSpex.Schema{type: :string, nullable: true},
          activeProfile: %OpenApiSpex.Schema{type: :string, nullable: true},
          profiles: %OpenApiSpex.Schema{type: :array, items: AnkoleWeb.Schemas.PodModels.Profile}
        },
        required: [:profile, :activeProfile, :profiles],
        additionalProperties: false
      },
      struct?: false
    )
  end
end
