defmodule AnkoleWeb.Telemetry do
  @moduledoc """
  Declares Phoenix, Repo, and VM metrics for control-plane observability.

  The module is intentionally reporter-neutral. Deployments can attach their own
  telemetry reporters without changing the application supervision tree.
  """

  use Supervisor
  import Telemetry.Metrics

  @doc """
  Starts the telemetry supervisor.
  """
  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  @spec init(term()) :: {:ok, tuple()} | :ignore
  def init(_arg) do
    children = [
      AnkoleWeb.RequestLogger,
      # Telemetry poller will execute the given period measurements
      # every 10_000ms. Learn more here: https://hexdocs.pm/telemetry_metrics
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
      # Add reporters as children of your supervision tree.
      # {Telemetry.Metrics.ConsoleReporter, metrics: metrics()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Returns the metric definitions exposed by the control plane.
  """
  @spec metrics() :: [Telemetry.Metrics.t()]
  def metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # Database Metrics
      summary("ankole.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("ankole.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      summary("ankole.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      summary("ankole.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      summary("ankole.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query"
      ),

      # Oban Worker Metrics
      summary("ankole.oban.job.stop.duration",
        tags: [:worker, :queue, :result],
        unit: {:native, :millisecond}
      ),

      # AIGateway hosted image-generation metrics. These events contain only
      # counts, byte sizes, latency, and provider routing identifiers.
      sum("ankole.ai_gateway.hosted_image_generation.count",
        tags: [:result, :failure_reason, :model, :provider_tag, :provider_slug]
      ),
      sum("ankole.ai_gateway.hosted_image_generation.hosted_tool_calls"),
      sum("ankole.ai_gateway.hosted_image_generation.successful_image_calls"),
      sum("ankole.ai_gateway.hosted_image_generation.main_model_rounds"),
      summary("ankole.ai_gateway.hosted_image_generation.image_latency_ms"),
      sum("ankole.ai_gateway.hosted_image_generation.input_bytes"),
      sum("ankole.ai_gateway.hosted_image_generation.output_bytes"),
      sum("ankole.ai_gateway.hosted_image_generation.partial_images"),
      sum("ankole.ai_gateway.hosted_image_generation.provider_cost"),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      # This function must call :telemetry.execute/3 and a metric must be added above.
      # {AnkoleWeb, :count_users, []}
    ]
  end
end
