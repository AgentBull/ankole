defmodule Ankole.AgentWorkers.Config do
  @moduledoc """
  Node startup facts shared by all Worker providers.

  Provider configuration lives in PostgreSQL. This node owns its target
  image, installation label, default connection endpoint, and development
  mounts. `observing_since` starts the rebuild clock when this node starts;
  time without a control plane does not count as a failed Worker start.
  """

  alias Ankole.RuntimeFabric

  @type t :: %{
          image: String.t(),
          runtime_fabric_endpoint: String.t(),
          installation: String.t(),
          protocol_version: pos_integer(),
          observing_since: DateTime.t(),
          source_root: String.t() | nil,
          internal_skills_root: String.t() | nil
        }

  @key {__MODULE__, :config}

  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  def start_link(_opts) do
    case put(Application.get_env(:ankole, Ankole.AgentWorkers)) do
      :ok ->
        :ignore

      {:error, :worker_runtime_not_configured} ->
        :persistent_term.erase(@key)
        :ignore

      {:error, reason} ->
        {:error, {:invalid_worker_runtime_config, reason}}
    end
  end

  @spec fetch() :: {:ok, t()} | {:error, :worker_runtime_not_configured}
  def fetch do
    case :persistent_term.get(@key, nil) do
      nil -> {:error, :worker_runtime_not_configured}
      config -> {:ok, config}
    end
  end

  @doc false
  def put(opts) do
    with {:ok, config} <- load(opts), do: :persistent_term.put(@key, config)
  end

  @spec load(keyword() | nil) :: {:ok, t()} | {:error, term()}
  def load(nil), do: {:error, :worker_runtime_not_configured}

  def load(opts) when is_list(opts) do
    with {:ok, image} <- required(opts, :image),
         {:ok, endpoint} <- required(opts, :runtime_fabric_endpoint),
         {:ok, installation} <- installation(Keyword.get(opts, :installation, "ankole")) do
      {:ok,
       %{
         image: image,
         runtime_fabric_endpoint: endpoint,
         installation: installation,
         protocol_version: RuntimeFabric.protocol_version(),
         observing_since: Keyword.get_lazy(opts, :observing_since, &database_now/0),
         source_root: Keyword.get(opts, :source_root),
         internal_skills_root: Keyword.get(opts, :internal_skills_root)
       }}
    end
  end

  defp installation(value) when is_binary(value) do
    if value =~ ~r/\A[a-z0-9]([a-z0-9-]{0,18}[a-z0-9])?\z/,
      do: {:ok, value},
      else: {:error, {:invalid_installation, value}}
  end

  defp installation(value), do: {:error, {:invalid_installation, value}}

  defp required(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _missing -> {:error, {:missing, key}}
    end
  end

  defp database_now do
    %Postgrex.Result{rows: [[now]]} = Ankole.Repo.query!("SELECT now()")
    now
  end
end
