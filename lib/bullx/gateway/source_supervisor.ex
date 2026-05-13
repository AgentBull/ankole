defmodule BullX.Gateway.SourceSupervisor do
  @moduledoc false

  use Supervisor

  alias BullX.Gateway.Sources

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    children =
      Sources.enabled!()
      |> Enum.map(&source_child_spec/1)
      |> Enum.reject(&(&1 == :ignore))

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp source_child_spec(%{adapter_module: module} = source) when is_atom(module) do
    module.source_child_spec(source)
  end
end
