defmodule BullxTelegram.SourceRuntime do
  @moduledoc false

  use Supervisor

  alias BullxTelegram.{Channel, Poller, Source}

  @registry BullxTelegram.Registry

  @spec child_spec(Source.t()) :: Supervisor.child_spec()
  def child_spec(%Source{} = source) do
    %{
      id: {__MODULE__, source.id},
      start: {__MODULE__, :start_link, [source]},
      restart: :permanent,
      type: :supervisor
    }
  end

  @spec start_link(Source.t()) :: Supervisor.on_start()
  def start_link(%Source{} = source) do
    Supervisor.start_link(__MODULE__, source, name: {:via, Registry, {@registry, {:source_runtime, source.id}}})
  end

  @impl true
  def init(%Source{} = source) do
    children = [Channel.child_spec(source), Poller.child_spec(source)]
    Supervisor.init(children, strategy: :one_for_all)
  end
end
