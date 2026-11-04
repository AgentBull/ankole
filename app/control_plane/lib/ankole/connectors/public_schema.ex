defmodule Ankole.Connectors.PublicSchema do
  @moduledoc false
  alias Ankole.Ash.Types.{JSONMap, UUIDv7}

  def connection_fields do
    [
      id: [type: UUIDv7, allow_nil?: false],
      plugin_id: [type: :string, allow_nil?: false],
      slug: [type: :string, allow_nil?: false],
      display_name: [type: :string, allow_nil?: false],
      auth_scheme: [type: :string, allow_nil?: false],
      is_default: [type: :boolean, allow_nil?: false],
      public_metadata: [type: JSONMap, allow_nil?: false],
      configured_credential_fields: [type: {:array, :string}, allow_nil?: false],
      status: [type: :string, allow_nil?: false],
      inserted_at: [type: :utc_datetime_usec, allow_nil?: false],
      updated_at: [type: :utc_datetime_usec, allow_nil?: false]
    ]
  end

  def catalog_fields do
    [
      id: [type: :string, allow_nil?: false],
      plugin_id: [type: :string, allow_nil?: false],
      display_name: [type: :string, allow_nil?: false],
      toolkits: [type: {:array, :string}, allow_nil?: false],
      auth_schemes: [type: {:array, :string}, allow_nil?: false],
      credential_fields: [type: {:array, JSONMap}],
      public_fields: [type: {:array, JSONMap}],
      trigger_types: [type: {:array, JSONMap}],
      event_streams: [
        type: {:array, :map},
        constraints: [
          items: [
            fields: [
              id: [type: :string, allow_nil?: false],
              label: [type: :string, allow_nil?: false],
              event_types: [type: {:array, :string}, allow_nil?: false]
            ]
          ]
        ]
      ]
    ]
  end
end
