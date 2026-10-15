defmodule Ankole.Plugins.EmailAdapter.ConnectionReconciler do
  @moduledoc false

  use Ankole.Plugins.ConnectionLifecycle,
    adapter: "email",
    registry: Ankole.Plugins.EmailAdapter.ConnectionRegistry,
    supervisor: Ankole.Plugins.EmailAdapter.ConnectionDynamicSupervisor,
    interval_ms: 30_000

  alias Ankole.Signals.Bindings
  alias Ankole.Plugins.EmailAdapter.Config
  alias Ankole.Plugins.EmailAdapter.ConnectionOwner
  alias Ankole.Plugins.EmailAdapter.Inbound
  alias Ankole.Conversations.AdapterContext
  alias Ankole.Signals.Binding

  @impl true
  def binding_spec(%Binding{} = binding, _opts) do
    case Bindings.binding_config(binding, Config) do
      {:ok, config} ->
        config = Config.runtime(config)

        context =
          AdapterContext.new(
            agent_uid: binding.agent_uid,
            binding_name: binding.name,
            adapter: binding.adapter,
            user_name: "Email"
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
    do: {context.agent_uid, context.binding_name}

  @impl true
  def owner_child_spec(key, config, [consumer]),
    do: {ConnectionOwner, key: key, config: config, consumer: consumer}
end
