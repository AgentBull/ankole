defmodule Ankole.Plugins.WeComAdapter.ConnectionReconciler do
  @moduledoc """
  Reconciles enabled WeCom bindings into long connections. Bindings of one
  bot share one connection. The WeCom identity provider uses REST only, so it
  adds no consumer.
  """

  use Ankole.Plugins.ConnectionLifecycle,
    adapter: "wecom",
    registry: Ankole.Plugins.WeComAdapter.ConnectionRegistry,
    supervisor: Ankole.Plugins.WeComAdapter.ConnectionDynamicSupervisor,
    conflict_reason: :conflicting_bot_secret

  alias Ankole.Signals.Bindings
  alias Ankole.Plugins.WeComAdapter.Config
  alias Ankole.Plugins.WeComAdapter.ConnectionOwner
  alias Ankole.Plugins.WeComAdapter.Inbound
  alias Ankole.Conversations.AdapterContext
  alias Ankole.Signals.Binding

  @impl true
  def binding_spec(%Binding{} = binding, _opts) do
    case Bindings.binding_config(binding, Config) do
      {:ok, config} ->
        context =
          AdapterContext.new(
            binding_id: binding.id,
            agent_uid: binding.agent_uid,
            binding_name: binding.name,
            adapter: binding.adapter,
            user_name: Map.get(config, "userName", "企业微信 / WeCom")
          )

        {:ok, connection_spec(config, Inbound.chat_consumer(context, config))}

      :error ->
        {:error, :chat_config_not_found}

      {:error, _reason} = error ->
        error
    end
  end

  @impl true
  def connection_key(config, _consumers), do: Config.connection_key(config)

  @impl true
  def owner_child_spec(_key, config, consumers),
    do: {ConnectionOwner, config: config, consumers: consumers}

  defp connection_spec(config, consumer) do
    %{
      config: config,
      secret_fingerprint: Config.secret_fingerprint(config),
      consumers: [consumer]
    }
  end
end
