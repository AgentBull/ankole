defmodule Ankole.AgentWorkers.WorkerBootstrap.AgentWorkerSpec do
  @moduledoc """
  The launch contract of one generation of one Agent's Worker.

  The provider mounts Agent storage before the Worker starts. `env` holds
  the contract variables, including the generation's credential. A platform
  with generated storage identifiers also receives the committed storage ref.
  `instance_ref` comes from the committed Worker row. Providers that deliver
  the credential after creation must use this reference to select the instance.
  """

  @type t :: %__MODULE__{
          agent_uid: String.t(),
          generation: String.t(),
          image: String.t(),
          instance_ref: String.t() | nil,
          create_retry?: boolean(),
          create_sent_at: DateTime.t() | nil,
          storage_ref: map() | nil,
          env: %{String.t() => String.t()}
        }

  @enforce_keys [:agent_uid, :generation, :image, :env]
  defstruct @enforce_keys ++
              [storage_ref: nil, instance_ref: nil, create_retry?: false, create_sent_at: nil]

  defimpl Inspect do
    def inspect(spec, opts) do
      env = Map.put(spec.env, "ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY", "[redacted]")
      Inspect.Map.inspect(%{spec | env: env} |> Map.from_struct(), opts)
    end
  end
end
