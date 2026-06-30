defmodule Ankole.PluginFixtures.InvalidAdapterModulePlugin do
  @moduledoc false

  @behaviour Ankole.Plugins.Plugin

  @impl true
  def plugin_id, do: "invalid-adapter-module"

  @impl true
  def api_version, do: 1

  @impl true
  def adapter_declarations do
    [
      %{
        contract_id: "principals.identity_provider",
        id: "missing-module",
        module: Ankole.PluginFixtures.MissingIdentityAdapter
      }
    ]
  end
end

defmodule Ankole.PluginFixtures.MissingIdentityCallbackPlugin do
  @moduledoc false

  @behaviour Ankole.Plugins.Plugin

  @impl true
  def plugin_id, do: "missing-identity-callback"

  @impl true
  def api_version, do: 1

  @impl true
  def adapter_declarations do
    [
      %{
        contract_id: "principals.identity_provider",
        id: "missing-callback",
        module: __MODULE__
      }
    ]
  end
end

defmodule Ankole.PluginFixtures.DuplicateAdapterPlugin do
  @moduledoc false

  @behaviour Ankole.Plugins.Plugin

  @impl true
  def plugin_id, do: "duplicate-adapter"

  @impl true
  def api_version, do: 1

  @impl true
  def adapter_declarations do
    [
      %{
        contract_id: "test.adapter",
        id: "alpha-adapter",
        module: __MODULE__
      }
    ]
  end
end

defmodule Ankole.PluginFixtures.MissingRemovedCallbackPlugin do
  @moduledoc false

  @behaviour Ankole.Plugins.Plugin

  @impl true
  def plugin_id, do: "missing-removed-callback"

  @impl true
  def api_version, do: 1

  @impl true
  def adapter_declarations do
    [
      %{
        contract_id: "signals_gateway.adapter",
        id: "missing-removed-callback",
        ingress_module: __MODULE__,
        inbound_capabilities: ["entry_removed"]
      }
    ]
  end

  def chat_consumer(_context, _config, _opts), do: %{}
end

defmodule Ankole.PluginFixtures.UnknownSignalsInboundCapabilityPlugin do
  @moduledoc false

  @behaviour Ankole.Plugins.Plugin

  @impl true
  def plugin_id, do: "unknown-signals-inbound-capability"

  @impl true
  def api_version, do: 1

  @impl true
  def adapter_declarations do
    [
      %{
        contract_id: "signals_gateway.adapter",
        id: "unknown-signals-inbound-capability",
        ingress_module: __MODULE__,
        inbound_capabilities: ["entry_receive", "made_up"]
      }
    ]
  end

  def chat_consumer(_context, _config, _opts), do: %{}
  def handle_message_receive(_event_type, _event, _consumers), do: {:ok, []}
end

defmodule Ankole.PluginFixtures.MissingAIGatewayProviderDefinitionPlugin do
  @moduledoc false

  @behaviour Ankole.Plugins.Plugin

  @impl true
  def plugin_id, do: "missing-ai-gateway-provider-definition"

  @impl true
  def api_version, do: 1

  @impl true
  def adapter_declarations do
    [
      %{
        contract_id: "ai_gateway.provider",
        id: "missing-provider-definition",
        module: __MODULE__
      }
    ]
  end
end

defmodule Ankole.PluginFixtures.MissingAIGatewayEmbeddingPreparePlugin do
  @moduledoc false

  @behaviour Ankole.Plugins.Plugin

  @impl true
  def plugin_id, do: "missing-ai-gateway-embedding-prepare"

  @impl true
  def api_version, do: 1

  @impl true
  def adapter_declarations do
    [
      %{
        contract_id: "ai_gateway.provider",
        id: "missing-embedding-prepare",
        module: __MODULE__
      }
    ]
  end

  def provider_definition do
    %Ankole.AIGateway.ProviderDefinition{
      provider_kind: "missing-embedding-prepare",
      label: %{"default" => "Missing Embedding Prepare"},
      module: __MODULE__,
      base_url: "https://example.test",
      capabilities: [
        %Ankole.AIGateway.ProviderDefinition.Capability{
          kind: :language_model,
          upstream: :sse,
          api_resolver: :openai_responses,
          prepare: :prepare_language_model
        },
        %Ankole.AIGateway.ProviderDefinition.Capability{
          kind: :embedding_model,
          upstream: :json,
          api_resolver: :openai_embeddings,
          prepare: :prepare_embedding_model
        }
      ]
    }
  end

  def prepare_language_model(_ctx), do: %{}
end
