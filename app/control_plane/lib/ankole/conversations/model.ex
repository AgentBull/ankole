defmodule Ankole.Conversations.Model do
  @moduledoc false
  alias Ankole.AIGateway
  alias Ankole.AIGateway.FailureDiagnostics
  alias Ankole.Conversations.{Ambient, Context, Fence, Prompt, Run, ToolCatalog}

  @spec prepare(Run.t()) :: {:ok, {atom(), Run.t()}} | {:error, term()}
  def prepare(run) do
    with {:ok, context} <- Context.resolve(run.agent_uid, run.session_id),
         {:ok, {state, run}} <- Ambient.prepare(%{run | context: context}) do
      if state == :ambient_skip, do: {:ok, {state, run}}, else: prepare_main(run)
    end
  end

  defp prepare_main(run) do
    context = run.context
    {tools, hosted} = ToolCatalog.for_run(run)
    run = %{run | tools: tools, hosted_tools: hosted}

    instructions =
      if run.kind == :workflow_task,
        do: Prompt.workflow_system(run),
        else:
          Prompt.system(%{
            context: context,
            agent_uid: run.agent_uid,
            workspace_id: run.workspace_id,
            hosted_tools: hosted,
            available_tool_names: Enum.map(tools, & &1.name),
            ambient_route: atom_route(run.spec.request_context["ambient"])
          })

    instructions =
      if run.kind == :scheduled,
        do: instructions <> "\n\n" <> Ankole.Conversations.Scheduled.reminder(run.event),
        else: instructions

    run = %{run | instructions: instructions}

    with {:ok, {state, run}} <- Run.restore(run) do
      if state == :preparing do
        input =
          if run.kind == :workflow_task and run.event.type == "workflow.task.dispatch",
            do: [Ankole.Conversations.Machine.user(run.spec.request_context["prompt"])],
            else: Prompt.user(run, run.delivered_event)

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
    AIGateway.open_websocket_stream(run.agent_uid, request(run),
      receiver: receiver,
      subject_type: "agent",
      caller: "conversation",
      request_context: run.spec.request_context,
      authorize_run_in_tx: &Fence.check_in_tx(&1, run)
    )
    |> case do
      {:error, reason} when reason in [:stale_driver, :run_closed, :actor_event_canceled] ->
        {:error, reason}

      {:error, reason} ->
        error = FailureDiagnostics.project(reason).error

        {:error,
         Map.put(error, "retryable", FailureDiagnostics.classify(reason)[:retryable] == true)}

      result ->
        result
    end
  end

  @spec request(Run.t()) :: map()
  def request(run) do
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

    request = Ankole.Attrs.maybe_put(request, "max_output_tokens", policy["max_output_tokens"])

    request =
      if run.kind == :scheduled,
        do:
          Map.put(request, "text", %{
            "format" => %{
              "type" => "json_schema",
              "name" => "scheduled_turn_result",
              "strict" => true,
              "schema" => %{
                "type" => "object",
                "properties" => %{
                  "outcome" => %{"type" => "string", "enum" => ["reply", "silent_success"]},
                  "reply" => %{"type" => ["string", "null"]}
                },
                "required" => ["outcome", "reply"],
                "additionalProperties" => false
              }
            }
          }),
        else: request

    request
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
  defp atom_route(nil), do: nil
  defp atom_route(route), do: %{action: route["action"], authority: route["authority"]}
end
