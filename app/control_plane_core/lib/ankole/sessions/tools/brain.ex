defmodule Ankole.Sessions.Tools.Brain do
  @moduledoc """
  The Job read-tool owner for the Brain read operations `recall` and `get_page`.

  A codex Job composes its own model requests, and in code mode the model can
  call only the tools that Codex itself declared. The hosted `brain` tool of a
  chat Session cannot reach that registry. The Worker therefore projects the
  read subset as dynamic Job tools and executes each call through the
  `tools.read` RPC. This owner runs the call with the shared Brain catalog: the
  Job's Agent is the querier, and the Job's Signal supplies the disclosure
  recipients, as it did for the hosted tool.
  """

  alias Ankole.Brain.RequestContext
  alias Ankole.Brain.Tools, as: Catalog
  alias Ankole.Sessions.JobTurnRef
  alias Ankole.Sessions.ToolResult
  alias Ankole.Sessions.Tools

  @operations ~w(recall get_page)
  @activities %{"recall" => "memory_recall", "get_page" => "memory_page_read"}

  @doc "Returns the read operation names in catalog order."
  @spec operations() :: [String.t()]
  def operations, do: @operations

  @doc "Returns the model-facing declarations of the Job read subset."
  @spec declarations() :: [map()]
  def declarations do
    Enum.map(Catalog.function_specs(@operations), fn spec ->
      Map.merge(spec, %{
        "activity" => Map.fetch!(@activities, spec["name"]),
        "execution_mode" => "parallel",
        "read_only" => true,
        "destructive" => false
      })
    end)
  end

  @doc """
  Runs one read operation for the Job attempt that the turn names.

  The Signal of the turn must belong to the Job's Agent; a Signal of another
  Agent or an unknown Signal refuses the read. The result output is the JSON
  document the model receives, with the lazy Skill hint first when the result
  names a Skill discovery record.
  """
  @spec read(JobTurnRef.t(), String.t(), map()) :: {:ok, ToolResult.t()} | {:error, term()}
  def read(%JobTurnRef{} = turn, operation, args) when operation in @operations do
    with {:ok, context} <-
           RequestContext.build(turn.agent_uid, %{"signal_id" => turn.signal_id}),
         {:ok, output} <- Catalog.execute(operation, args, context) do
      {:ok, Tools.result(output, text: output_text(output))}
    end
  end

  def read(%JobTurnRef{}, operation, _args), do: {:error, {:unknown_operation, operation}}

  defp output_text(output) do
    prefix = if Catalog.lazy_skill_result?(output), do: Catalog.lazy_skill_hint(), else: ""
    prefix <> Ankole.JSON.encode!(output)
  end
end
