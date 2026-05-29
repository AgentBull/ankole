defmodule BullX.Runtime.Supervisor do
  @moduledoc false
  use Supervisor

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, :ok, name: name)
  end

  @impl true
  def init(:ok) do
    children =
      [
        BullX.LLM.PluginProviders,
        BullX.LLM.Catalog.Cache,
        BullX.Redis,
        mail_box_dispatcher_child(),
        BullX.AIAgent.AmbientBatchWorker,
        BullX.AIAgent.DailyResetWorker
      ]
      |> List.flatten()

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp mail_box_dispatcher_child do
    config = Application.get_env(:bullx, :mail_box, [])

    case Keyword.get(config, :dispatcher, true) do
      true ->
        [
          {BullX.MailBox.Dispatcher,
           interval_ms: Keyword.get(config, :dispatcher_interval_ms, 500),
           claim_limit: Keyword.get(config, :dispatcher_claim_limit, 20)}
        ]

      false ->
        []
    end
  end
end
