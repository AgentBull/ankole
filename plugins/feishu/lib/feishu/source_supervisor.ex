defmodule Feishu.SourceSupervisor do
  @moduledoc false

  use Supervisor

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    children =
      Feishu.Source.enabled_sources!()
      |> Enum.map(&Feishu.Channel.child_spec/1)

    Supervisor.init(children, strategy: :one_for_one)
  end
end
