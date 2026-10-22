defmodule Ankole.AgentWorkers.Domain do
  @moduledoc "Worker configuration and the durable lifecycle of each Agent's Worker."
  use Ankole.Ash.Domain

  resources do
    resource Ankole.AgentWorkers.Providers.Provider do
      define(:get_provider, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_providers, action: :read)
      define(:create_provider, action: :create)
      define(:configure_provider, action: :configure)
      define(:unset_default_provider, action: :unset_default)
      define(:remove_provider, action: :remove)
    end

    resource Ankole.AgentWorkers.AgentWorker do
      define(:get_agent_worker, action: :read, get_by: [:agent_uid], not_found_error?: false)
      define(:list_agent_workers, action: :read)
      define(:register_agent_worker, action: :register)
      define(:reserve_slot_agent_worker, action: :reserve_slot)
      define(:request_agent_worker, action: :request)
      define(:heartbeat_agent_worker, action: :heartbeat)
      define(:observe_agent_worker, action: :observe)
      define(:record_error_agent_worker, action: :record_error)
      define(:clear_rejection_agent_worker, action: :clear_rejection)
      define(:assign_provider_agent_worker, action: :assign_provider)
      define(:remove_agent_worker, action: :remove)
    end
  end
end
