defmodule Ankole.Plugins.DiscordAdapter.ConnectionReconciler do
  @moduledoc false

  use Ankole.Plugins.ConnectionLifecycle,
    adapter: "discord",
    registry: Ankole.Plugins.DiscordAdapter.ConnectionRegistry,
    supervisor: Ankole.Plugins.DiscordAdapter.ConnectionDynamicSupervisor,
    interval_ms: 30_000

  alias Ankole.Signals.Bindings
  alias Ankole.Plugins.DiscordAdapter.Config
  alias Ankole.Plugins.DiscordAdapter.ConnectionOwner
  alias Ankole.Plugins.DiscordAdapter.Inbound
  alias Ankole.Conversations.AdapterContext
  alias Ankole.Signals.Binding

  @impl true
  def binding_spec(%Binding{} = binding, _opts) do
    case Bindings.binding_config(binding, Config) do
      {:ok, config} ->
        config = Config.runtime_config(config)

        context =
          AdapterContext.new(
            binding_id: binding.id,
            agent_uid: binding.agent_uid,
            binding_name: binding.name,
            adapter: binding.adapter,
            user_name: "Discord"
          )

        {:ok, %{config: config, consumers: [Inbound.chat_consumer(context, config)]}}

      :error ->
        {:error, :config_not_found}

      {:error, _reason} = error ->
        error
    end
  end

  @impl true
  def connection_key(_config, [%{context: %AdapterContext{} = context}]),
    do: context.binding_id

  @impl true
  def owner_child_spec(key, config, [consumer]),
    do: {ConnectionOwner, key: key, config: config, consumer: consumer}
end
