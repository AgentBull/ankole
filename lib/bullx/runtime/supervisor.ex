defmodule BullX.Runtime.Supervisor do
  @moduledoc """
  Supervises BullX runtime workers after static infrastructure is ready.

  The children here own ephemeral process activity: plugin provider projection,
  Redis client ownership, MailBox dispatch polling, and AIAgent background
  workers. Durable business truth remains in PostgreSQL; these processes must
  be safe to restart and reconstruct.
  """

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
        {Task.Supervisor, name: BullX.MailBox.RuntimeTaskSupervisor},
        mail_box_runtime_child(),
        ambient_batch_children(),
        ai_agent_runtime_child(:daily_reset_worker, BullX.AIAgent.DailyResetWorker)
      ]
      |> List.flatten()

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp mail_box_runtime_child do
    config = Application.get_env(:bullx, :mail_box, [])

    case Keyword.get(config, :runtime, true) do
      true ->
        [
          {BullX.MailBox.Runtime,
           dispatch?: Keyword.get(config, :runtime_dispatcher, true),
           control_dispatch?: Keyword.get(config, :runtime_control_dispatcher, true),
           interval_ms: Keyword.get(config, :runtime_interval_ms, 500),
           claim_limit: Keyword.get(config, :runtime_claim_limit, 20)}
        ]

      false ->
        []
    end
  end

  defp ambient_batch_children do
    config = Application.get_env(:bullx, :ai_agent_runtime, [])

    case Keyword.get(config, :ambient_batch_worker, true) do
      true ->
        [
          Supervisor.child_spec(
            {Task.Supervisor, name: BullX.AIAgent.AmbientBatchTaskSupervisor},
            id: BullX.AIAgent.AmbientBatchTaskSupervisor
          ),
          BullX.AIAgent.AmbientBatchWorker
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
