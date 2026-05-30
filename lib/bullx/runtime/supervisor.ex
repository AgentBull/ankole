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
        {Task.Supervisor, name: BullX.MailBox.SessionWorkerSupervisor},
        mail_box_dispatcher_child(),
        ai_agent_runtime_child(:ambient_batch_worker, BullX.AIAgent.AmbientBatchWorker),
        ai_agent_runtime_child(:daily_reset_worker, BullX.AIAgent.DailyResetWorker)
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

  defp ai_agent_runtime_child(config_key, child) do
    config = Application.get_env(:bullx, :ai_agent_runtime, [])

    case Keyword.get(config, config_key, true) do
      true -> [child]
      false -> []
    end
  end
end
