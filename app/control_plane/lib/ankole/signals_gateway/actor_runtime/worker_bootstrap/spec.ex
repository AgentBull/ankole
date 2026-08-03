defmodule Ankole.SignalsGateway.ActorRuntime.WorkerBootstrap.Spec do
  @moduledoc """
  Versioned structured contract consumed by Agent Computer launch adapters.
  """

  @type mount :: %{
          source: String.t(),
          target: String.t(),
          readonly: boolean()
        }

  @type host_alias :: %{
          host: String.t(),
          address: String.t()
        }

  @type docker :: %{
          cap_add: [String.t()],
          security_opts: [String.t()],
          extra_hosts: [host_alias()]
        }

  @type t :: %__MODULE__{
          contract_version: 3,
          kind: :container | :worker,
          image: String.t(),
          docker: docker(),
          env: %{String.t() => String.t()},
          host_setup_dirs: [String.t()],
          mounts: [mount()]
        }

  @enforce_keys [
    :contract_version,
    :kind,
    :image,
    :docker,
    :env,
    :host_setup_dirs,
    :mounts
  ]
  defstruct @enforce_keys
end
