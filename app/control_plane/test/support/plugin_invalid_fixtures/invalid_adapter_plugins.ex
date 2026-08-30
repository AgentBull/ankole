defmodule Ankole.PluginFixtures.InvalidAdapterModulePlugin do
  @moduledoc false

  @behaviour Ankole.Plugins.Plugin

  @impl true
  def plugin_id, do: "invalid-adapter-module"

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

defmodule Ankole.PluginFixtures.StringLocalizedTextPlugin do
  @moduledoc false

  @behaviour Ankole.Plugins.Plugin

  @impl true
  def plugin_id, do: "string-localized-text"

  @impl true
  def display_name, do: "String Display Name"
end

defmodule Ankole.PluginFixtures.MissingDefaultLocalizedTextPlugin do
  @moduledoc false

  @behaviour Ankole.Plugins.Plugin

  @impl true
  def plugin_id, do: "missing-default-localized-text"

  @impl true
  def display_name, do: %{"en-US" => "Missing Default"}
end

defmodule Ankole.PluginFixtures.StringAdapterDisplayNamePlugin do
  @moduledoc false

  @behaviour Ankole.Plugins.Plugin

  @impl true
  def plugin_id, do: "string-adapter-display-name"

  @impl true
  def adapter_declarations do
    [
      %{
        contract_id: "test.adapter",
        id: "string-display",
        display_name: "String Display Name"
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
  def adapter_declarations do
    [
      %{
        contract_id: "principals.identity_provider",
        id: "missing-callback",
        module: __MODULE__,
        capabilities: ["directory_full_sync"]
      }
    ]
  end

  # Declares directory sync but does not export upsert_user, the callback that
  # capability requires.
  def sync_directory(_provider_id, _config, _opts), do: {:ok, %{users: 0, departments: 0}}
end

defmodule Ankole.PluginFixtures.DuplicateAdapterPlugin do
  @moduledoc false

  @behaviour Ankole.Plugins.Plugin

  @impl true
  def plugin_id, do: "duplicate-adapter"

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
  def adapter_declarations do
    [
      %{
        contract_id: "signals_gateway.adapter",
        id: "missing-removed-callback",
        adapter_category: "enterprise_im",
        ingress_module: __MODULE__,
        inbound_capabilities: ["entry_removed"]
      }
    ]
  end

  def chat_consumer(_context, _config), do: %{}
end

defmodule Ankole.PluginFixtures.UnknownSignalsInboundCapabilityPlugin do
  @moduledoc false

  @behaviour Ankole.Plugins.Plugin

  @impl true
  def plugin_id, do: "unknown-signals-inbound-capability"

  @impl true
  def adapter_declarations do
    [
      %{
        contract_id: "signals_gateway.adapter",
        id: "unknown-signals-inbound-capability",
        adapter_category: "enterprise_im",
        ingress_module: __MODULE__,
        inbound_capabilities: ["entry_receive", "made_up"]
      }
    ]
  end

  def chat_consumer(_context, _config), do: %{}
  def handle_message_receive(_event_type, _event, _consumers), do: {:ok, []}
end

defmodule Ankole.PluginFixtures.UnknownSignalsOutboundCapabilityPlugin do
  @moduledoc false

  @behaviour Ankole.Plugins.Plugin

  @impl true
  def plugin_id, do: "unknown-signals-outbound-capability"

  @impl true
  def adapter_declarations do
    [
      %{
        contract_id: "signals_gateway.adapter",
        id: "unknown-signals-outbound-capability",
        adapter_category: "enterprise_im",
        outbox_module: __MODULE__,
        outbound_capabilities: ["post_entry", "made_up"]
      }
    ]
  end

  def send(_outbox), do: {:ok, %{}}
end

defmodule Ankole.PluginFixtures.MissingSignalsOutboxSendPlugin do
  @moduledoc false

  @behaviour Ankole.Plugins.Plugin

  @impl true
  def plugin_id, do: "missing-signals-outbox-send"

  @impl true
  def adapter_declarations do
    [
      %{
        contract_id: "signals_gateway.adapter",
        id: "missing-signals-outbox-send",
        adapter_category: "enterprise_im",
        outbox_module: __MODULE__,
        outbound_capabilities: ["post_entry"]
      }
    ]
  end
end

defmodule Ankole.PluginFixtures.MissingSignalsOutboxReconcilePlugin do
  @moduledoc false

  @behaviour Ankole.Plugins.Plugin

  @impl true
  def plugin_id, do: "missing-signals-outbox-reconcile"

  @impl true
  def adapter_declarations do
    [
      %{
        contract_id: "signals_gateway.adapter",
        id: "missing-signals-outbox-reconcile",
        adapter_category: "enterprise_im",
        outbox_module: __MODULE__,
        outbound_capabilities: ["post_entry", "outbound_reconciliation"]
      }
    ]
  end

  def send(_outbox), do: {:ok, %{}}
end

defmodule Ankole.PluginFixtures.UnknownIdentityCapabilityPlugin do
  @moduledoc false

  @behaviour Ankole.Plugins.Plugin

  @impl true
  def plugin_id, do: "unknown-identity-capability"

  @impl true
  def adapter_declarations do
    [
      %{
        contract_id: "principals.identity_provider",
        id: "unknown-identity-capability",
        module: __MODULE__,
        capabilities: ["directory_full_sync", "made_up"]
      }
    ]
  end

  def upsert_user(_provider_id, _user), do: {:ok, %{}}
  def sync_directory(_provider_id, _config, _opts), do: {:ok, %{users: 0, departments: 0}}
end

defmodule Ankole.PluginFixtures.MissingAIGatewayProviderDefinitionPlugin do
  @moduledoc false

  @behaviour Ankole.Plugins.Plugin

  @impl true
  def plugin_id, do: "missing-ai-gateway-provider-definition"

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
  def adapter_declarations do
    [
      %{
        contract_id: "ai_gateway.provider",
        id: "missing_embedding_prepare",
        module: __MODULE__
      }
    ]
  end

  def provider_definition do
    %Ankole.AIGateway.ProviderDefinition{
      provider_kind: "missing_embedding_prepare",
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

defmodule Ankole.PluginFixtures.KebabAIGatewayProviderKindPlugin do
  @moduledoc false

  @behaviour Ankole.Plugins.Plugin

  @impl true
  def plugin_id, do: "kebab-ai-gateway-provider-kind"

  @impl true
  def adapter_declarations do
    [
      %{
        contract_id: "ai_gateway.provider",
        id: "kebab-provider",
        module: __MODULE__
      }
    ]
  end

  def provider_definition do
    %Ankole.AIGateway.ProviderDefinition{
      provider_kind: "kebab-provider",
      label: %{"default" => "Kebab Provider Kind"},
      module: __MODULE__,
      base_url: "https://example.test",
      capabilities: [
        %Ankole.AIGateway.ProviderDefinition.Capability{
          kind: :language_model,
          upstream: :sse,
          api_resolver: :openai_responses,
          prepare: :prepare_language_model
        }
      ]
    }
  end

  def prepare_language_model(_ctx), do: %{}
end
