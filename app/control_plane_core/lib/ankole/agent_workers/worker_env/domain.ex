defmodule Ankole.AgentWorkers.WorkerEnv.Domain do
  @moduledoc "Durable site and tenant shell variables."
  use Ankole.Ash.Domain

  resources do
    resource Ankole.AgentWorkers.WorkerEnv.EnvVar do
      define(:get_env_var, action: :read, get_by: [:scope, :name], not_found_error?: false)
      define(:list_env_vars, action: :read)
      define(:put_env_var, action: :put)
      define(:remove_env_var, action: :remove)
    end

    resource Ankole.AgentWorkers.WorkerEnv.SiteEnvVar do
      define(:get_site_env_var, action: :read, get_by: [:scope, :name], not_found_error?: false)
      define(:list_site_env_vars, action: :read)
      define(:put_site_env_var, action: :put)
      define(:remove_site_env_var, action: :remove)
    end
  end
end
