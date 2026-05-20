defmodule BullXWeb.Api.Schemas do
  @moduledoc """
  OpenAPI schemas for the internal console API (`/.internal-apis/v1`).

  Channels are adapter-driven: the stable envelope is `(adapter_id, id, enabled)`
  plus an adapter-specific `config`/`source` object. Per-adapter field shapes are
  described at runtime by the adapter's `form_schema` (see `ChannelAdapter`), so
  the config payloads here are intentionally free-form objects.
  """

  alias OpenApiSpex.Schema

  defmodule Channel do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Channel",
      description: "A configured channel source, identified by (adapter_id, id).",
      type: :object,
      properties: %{
        adapter_id: %Schema{type: :string, description: "Channel adapter id, e.g. \"feishu\"."},
        id: %Schema{type: :string, description: "Source id within the adapter, e.g. \"main\"."},
        enabled: %Schema{type: :boolean},
        config: %Schema{
          type: :object,
          additionalProperties: true,
          description: "Public source projection. Secret fields are masked to {present: boolean}."
        }
      },
      required: [:adapter_id, :id, :enabled, :config],
      additionalProperties: false
    })
  end

  defmodule ChannelList do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ChannelList",
      type: :object,
      properties: %{data: %Schema{type: :array, items: Channel}},
      required: [:data],
      additionalProperties: false
    })
  end

  defmodule ChannelAdapter do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ChannelAdapter",
      description: "An available channel adapter and the schema describing its config form.",
      type: :object,
      properties: %{
        id: %Schema{type: :string},
        plugin_id: %Schema{type: :string},
        label: %Schema{type: :string},
        form_schema: %Schema{
          type: :object,
          additionalProperties: true,
          description: "Adapter-provided form schema (sections, fields, defaults)."
        }
      },
      required: [:id, :plugin_id, :label, :form_schema],
      additionalProperties: false
    })
  end

  defmodule ChannelAdapterList do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ChannelAdapterList",
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: ChannelAdapter},
        oidc_callback_url_template: %Schema{
          type: :string,
          description: "OIDC callback URL with __source_id__ placeholder for the source id."
        }
      },
      required: [:data, :oidc_callback_url_template],
      additionalProperties: false
    })
  end

  defmodule ChannelCreateRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ChannelCreateRequest",
      type: :object,
      properties: %{
        adapter_id: %Schema{type: :string},
        source: %Schema{
          type: :object,
          additionalProperties: true,
          description:
            "Raw form values for the source (must include id for multi-source adapters)."
        }
      },
      required: [:adapter_id, :source],
      additionalProperties: false
    })
  end

  defmodule ChannelUpdateRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ChannelUpdateRequest",
      type: :object,
      properties: %{
        source: %Schema{
          type: :object,
          additionalProperties: true,
          description: "Raw form values. Omitted secret fields keep their stored value."
        }
      },
      required: [:source],
      additionalProperties: false
    })
  end

  defmodule ConnectivityCheckRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ConnectivityCheckRequest",
      type: :object,
      properties: %{
        adapter_id: %Schema{type: :string},
        source: %Schema{type: :object, additionalProperties: true}
      },
      required: [:adapter_id, :source],
      additionalProperties: false
    })
  end

  defmodule ConnectivityCheckResult do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ConnectivityCheckResult",
      type: :object,
      properties: %{
        ok: %Schema{type: :boolean},
        result: %Schema{type: :object, additionalProperties: true}
      },
      required: [:ok, :result],
      additionalProperties: false
    })
  end

  defmodule Error do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Error",
      type: :object,
      properties: %{
        message: %Schema{type: :string},
        field: %Schema{type: :string, nullable: true},
        errors: %Schema{
          type: :array,
          items: %Schema{type: :object, additionalProperties: true},
          nullable: true
        }
      },
      required: [:message],
      additionalProperties: true
    })
  end
end
