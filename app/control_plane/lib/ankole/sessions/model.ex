defmodule Ankole.Sessions.Model do
  alias Ankole.AIGateway.FailureResponse
  @moduledoc false
  alias Ankole.AIGateway
  alias Ankole.AIGateway.FailureDiagnostics
  alias Ankole.Sessions.Context
  alias Ankole.Sessions.Fence
  alias Ankole.Sessions.Run
  alias Ankole.Sessions.ToolCatalog

  @spec prepare(Run.t()) :: {:ok, {atom(), Run.t()}} | {:error, term()}
  def prepare(run) do
    with {:ok, context} <- Context.resolve(run.agent_uid, run.session_id),
         {:ok, {state, run}} <- Run.type(run).prepare(%{run | context: context}) do
      if state == :ambient_skip, do: {:ok, {state, run}}, else: prepare_main(run)
    end
  end

  defp prepare_main(run) do
    {tools, hosted} = ToolCatalog.for_run(run)
    run = %{run | tools: tools, hosted_tools: hosted}
    run = %{run | instructions: Run.type(run).instructions(run)}

    with {:ok, {state, run}} <- Run.restore(run) do
      if state == :preparing do
        input = Run.type(run).input(run)

        # Only input that an earlier attempt already injected joins the first
        # request. Newer input waits for the next boundary.
        with {:ok, _injected, run} <-
               Run.inject_pending(%{run | input: input}, & &1.last_attempt_at),
             do: {:ok, {state, run}}
      else
        {:ok, {state, run}}
      end
    end
  end

  @spec open(Run.t(), pid()) ::
          {:ok, Ankole.AIGateway.ResponseStream.t(), map()} | {:error, term()}
  def open(run, receiver) do
    request = Ankole.Sessions.ConversationContext.append(run, base_request(run))

    with {:ok, brain_context} <-
           Ankole.Brain.RequestContext.build(run.agent_uid, Run.metadata(run)) do
      AIGateway.open_websocket_stream(run.agent_uid, request,
        receiver: receiver,
        brain_context: brain_context,
        subject_type: "agent",
        caller: "conversation",
        request_context: run.spec.request_context,
        response_metadata:
          Ankole.Attrs.maybe_put(%{}, "model_profile", run.spec.model_ref["profile"]),
        authorize_run_in_tx: fn repo ->
          Fence.check_in_tx(repo, run)
        end,
        record_response_in_tx: &Ankole.Sessions.RoundState.put_in_tx(&1, run, &2)
      )
    end
    |> case do
      {:error, reason}
      when reason in [:stale_driver, :run_closed, :signal_canceled] ->
        {:error, reason}

      {:error, reason} ->
        error = FailureResponse.project(reason).error

        {:error,
         Map.put(error, "retryable", FailureDiagnostics.classify(reason)[:retryable] == true)}

      result ->
        result
    end
  end

  @spec request(Run.t()) :: map()
  def request(run),
    do: run |> base_request() |> then(&Ankole.Sessions.ConversationContext.append(run, &1))

  defp base_request(run) do
    model = run.spec.model_ref
    policy = run.spec.request_context["ai_agent"]

    request = %{
      "model" => selector(model),
      "provider_options" => model["provider_options"] || %{},
      "store" => true,
      "conversation" => "conv_#{run.conversation.id}",
      # Every round of one conversation shares its prompt prefix and its
      # credential affinity.
      "prompt_cache_key" => "conv_#{run.conversation.id}",
      "instructions" => run.instructions,
      "input" => run.input,
      "metadata" => Run.metadata(run),
      "tools" => ToolCatalog.wire(run.tools) ++ run.hosted_tools,
      "parallel_tool_calls" => model["supports_parallel_tool_calls"] == true,
      "__ankole_codex_vision" => vision(model)
    }

    request =
      request
      |> Ankole.Attrs.maybe_put("max_output_tokens", policy["max_output_tokens"])

    request
  end

  def inactivity_deadline(run) do
    timeout = inactivity_timeout(run)

    [
      {{:timeout, :model_activity}, if(timeout > 0, do: timeout, else: :infinity),
       {run.epoch, run.iteration}}
    ]
  end

  defp inactivity_timeout(run) do
    get_in(run.spec.request_context, ["ai_agent", "inactivity_timeout_ms"]) ||
      Ankole.Sessions.AgentConfig.default_inactivity_timeout_ms()
  end

  @doc "The image input of the model and its frozen vision fallback, as AIGateway reads it."
  @spec vision(map()) :: map()
  def vision(model),
    do: %{
      "input_modalities" => model["input_modalities"] || [],
      "vision_fallback" => fallback(model["vision_fallback_model_ref"])
    }

  defp fallback(nil), do: nil

  defp fallback(model),
    do: %{
      "selector" => selector(model),
      "provider_options" => model["provider_options"] || %{},
      "input_modalities" => model["input_modalities"] || []
    }

  @doc false
  def selector(%{"provider_id" => "ai_gateway", "model" => model}), do: model
  def selector(model), do: "#{model["provider_id"]}/#{model["model"]}"
end
