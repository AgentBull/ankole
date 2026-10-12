defmodule Ankole.Conversations.RunType do
  @moduledoc "The admission and execution contract shared by conversation run types."

  alias Ankole.Conversations.Run
  alias Ankole.SignalsGateway.ActorEvent

  @callback prepare_input(ActorEvent.t(), DateTime.t()) ::
              {:ok, ActorEvent.t()} | {:closed, map()} | {:error, term()}
  @callback plan(ActorEvent.t(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback admit_in_tx(module(), ActorEvent.t(), map()) :: {:ok, map()} | {:error, term()}
  @callback finalize_input_in_tx(module(), ActorEvent.t(), map()) ::
              {:ok, :not_committed | map()} | {:error, term()}
  @callback fail_exhausted_in_tx(module(), ActorEvent.t(), map(), term()) ::
              :ok | {:error, term()}
  @callback prepare(Run.t()) :: {:ok, {atom(), Run.t()}} | {:error, term()}
  @callback lock_progress_in_tx(module(), Run.t()) :: {:ok, term()} | {:error, term()}
  @callback restore_attempt(Run.t(), term(), term()) :: Run.t()
  @callback instructions(Run.t()) :: String.t()
  @callback input(Run.t()) :: [map()]
  @callback tools(Run.t(), [map()], [map()]) :: {[map()], [map()]}
  @callback project_completion(Run.t(), map()) :: {:ok, map()} | {:error, term()}
  @callback nudge?() :: boolean()
  @callback repair(Run.t(), String.t()) :: {String.t(), Run.t()} | nil
  @callback finish(Run.t()) :: {:finalize, Run.t()} | {:workflow_failure, Run.t(), map()}
  @callback failure(term()) :: {:execution_error | :workflow_failure, map()}

  defmacro __using__(_opts) do
    quote do
      @behaviour Ankole.Conversations.RunType

      def prepare_input(event, _now), do: {:ok, event}
      def prepare(run), do: {:ok, {:prepare, run}}
      def admit_in_tx(_repo, _event, _plan), do: {:ok, %{}}
      def finalize_input_in_tx(_repo, _event, _plan), do: {:ok, :not_committed}
      def fail_exhausted_in_tx(_repo, _event, _plan, _reason), do: :ok
      def lock_progress_in_tx(_repo, _run), do: {:ok, nil}
      def restore_attempt(run, _latest, _state), do: run
      def project_completion(_run, completion), do: {:ok, completion}
      def nudge?, do: true
      def finish(run), do: {:finalize, run}

      def failure(reason) do
        error =
          cond do
            is_map(reason) ->
              reason

            reason == :turn_completion_has_no_user_visible_projection ->
              %{
                "code" => Atom.to_string(reason),
                "message" => "The model result did not satisfy the completion contract.",
                "retryable" => false
              }

            true ->
              %{
                "code" => "conversation_execution_error",
                "message" => inspect(reason),
                "retryable" => true
              }
          end

        {:execution_error, error}
      end

      def repair(run, text) do
        if String.trim(text) == "" and not run.visible_delivery? do
          {"You ended your turn with no visible output. This turn was started by an event that requires one, and this turn cannot complete without it: nothing you did reaches the user unless the turn ends with final reply text, a clarify question, or a reply_attachment delivery.\nEnd the turn now with a short final reply. If you already delivered the result through reply_attachment or a generated image, reply with one short closing line. If you are blocked, state plainly what blocked you and what you need.",
           run}
        end
      end

      def instructions(run) do
        route = run.spec.request_context["ambient"]

        Ankole.Conversations.Prompt.system(%{
          context: run.context,
          agent_uid: run.agent_uid,
          workspace_id: run.workspace_id,
          hosted_tools: run.hosted_tools,
          available_tool_names: Enum.map(run.tools, & &1.name),
          ambient_route: if(route, do: %{action: route["action"], authority: route["authority"]})
        })
      end

      def input(run), do: Ankole.Conversations.Prompt.user(run, run.delivered_event)

      def tools(_run, tools, hosted) do
        {tools,
         Enum.map(hosted, fn tool ->
           if tool["type"] == "brain", do: Map.put(tool, "inject", true), else: tool
         end)}
      end

      defoverridable prepare_input: 2,
                     prepare: 1,
                     admit_in_tx: 3,
                     finalize_input_in_tx: 3,
                     fail_exhausted_in_tx: 4,
                     lock_progress_in_tx: 2,
                     restore_attempt: 3,
                     project_completion: 2,
                     nudge?: 0,
                     finish: 1,
                     failure: 1,
                     repair: 2,
                     instructions: 1,
                     input: 1,
                     tools: 3
    end
  end
end
