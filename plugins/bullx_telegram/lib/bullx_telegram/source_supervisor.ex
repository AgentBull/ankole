defmodule BullxTelegram.SourceSupervisor do
  @moduledoc false

  use Supervisor

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    children =
      [
        {Registry, keys: :unique, name: BullxTelegram.Registry}
        | Enum.map(BullxTelegram.Source.enabled_sources!(), &BullxTelegram.SourceRuntime.child_spec/1)
      ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
