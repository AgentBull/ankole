defmodule Ankole.Sessions.AmbientTriage do
  @moduledoc """
  Classifies ambient input before a foreground turn is admitted.

  `run/2` gives one of these results:

    * `{:ok, :intervene, signal}` - the Agent may reply or start work; admit the input.
    * `{:ok, :settled}` - the input is closed or another input replaced it.
    * `{:ok, :deferred, signal}` - classification failed; retry at `signal.available_at`.
    * `{:error, reason}` - the input stays unchanged.
  """
  require Ash.Query

  alias Ankole.AIGateway
  alias Ankole.AIAgent.TokenQuota

  alias Ankole.Sessions.{
    Ambient,
    AmbientCuration,
    AmbientJudgment,
    Admission,
    Context,
    Run,
    Model,
    Prompt,
    Queue
  }

  alias Ankole.Sessions.AmbientTriage.Observation
  alias Ankole.Signals.Signal

  @type result ::
          {:ok, :intervene, Signal.t()}
          | {:ok, :settled}
          | {:ok, :deferred, Signal.t()}
          | {:error, term()}

  @spec run(map(), Signal.t()) :: result()
  def run(key, event) do
    now = DateTime.utc_now(:microsecond)

    case Ambient.resolve(event, now) do
      {:ok, %{status: :ambient_fresh, signal: current}} ->
        case AmbientJudgment
             |> Ash.Query.filter(signal_id == ^current.id)
             |> Ankole.Ash.read_one!() do
          %AmbientJudgment{} = judgment -> result(current, judgment)
          nil -> classify(key, current)
        end

      {:ok, _closed} ->
        {:ok, :settled}

      {:error, _reason} = error ->
        error
    end
  end

  defp classify(key, event) do
    with :ok <- TokenQuota.ensure_available(key.agent_uid),
         {:ok, context} <- Context.ambient_observation(event),
         {:ok, runtime} <- Context.runtime(key, profile: "light"),
         observation = %Observation{
           agent_uid: key.agent_uid,
           event: event,
           context: context,
           model_ref: runtime.model_ref,
           request_context:
             Map.put(
               runtime.request_context,
               "ambient_work_candidates",
               Ambient.candidates(event)
             )
         },
         {:ok, attrs} <- recognize(observation) do
      commit(key, event, attrs)
    else
      {:error, {:model_profile_unavailable, _profile, _reason}} ->
        complete_without_model(key, event, "The ambient model profile is unavailable.")

      {:error, {:agent_token_quota_exceeded, _window}} ->
        complete_without_model(
          key,
          event,
          "The Agent has used its token quota for the current period."
        )

      {:error, _reason} ->
        retry(key, event)
    end
  end

  defp recognize(observation) do
    {input, schema, delta, orders?} = Observation.render(observation)
    model = observation.model_ref

    request = %{
      "model" => Model.selector(model),
      "provider_options" => model["provider_options"] || %{},
      "instructions" => Prompt.ambient_system(observation),
      "input" => [Run.user(input)],
      "max_output_tokens" => 300,
      "temperature" => 0,
      "text" => %{
        "format" => %{
          "type" => "json_schema",
          "name" => "ambient_intent_route",
          "strict" => true,
          "schema" => schema
        }
      }
    }

    with {:ok, %{body: body}} <-
           AIGateway.create_response(observation.agent_uid, request,
             subject_type: "agent",
             caller: "ambient",
             request_context: observation.request_context
           ),
         {:ok, text} <- AIGateway.completed_output_text(body) do
      value = Observation.decision(text, schema, delta, orders?)

      {:ok,
       %{
         action: value["action"],
         authority: value["authority"],
         handoff_job_id: value["handoff_job_id"] && String.to_integer(value["handoff_job_id"]),
         reason: value["reason"],
         asked_by_message_id: value["asked_by_message_id"],
         asked_by_state: value["asked_by_state"]
       }}
    end
  end

  defp commit(key, event, attrs) do
    case AmbientCuration.record_judgment(key, event.id, attrs) do
      {:ok, judgment} ->
        result(Ankole.Signals.get_signal!(event.id), judgment)

      {:error, {:ambient_stale, _reason}} ->
        with {:ok, _closed} <- Ambient.resolve(event, DateTime.utc_now(:microsecond)),
             do: {:ok, :settled}

      error ->
        error
    end
  end

  defp result(event, %{action: action}) when action in ["FOREGROUND_REPLY", "NEW_WORK"],
    do: {:ok, :intervene, event}

  defp result(_event, _judgment), do: {:ok, :settled}

  # A NOOP judgment settles the input without a model call and without a notice.
  defp complete_without_model(key, event, reason),
    do: commit(key, event, %{action: "NOOP", authority: "NONE", reason: reason})

  defp retry(key, event) do
    key
    |> Ankole.Sessions.retry_ambient_triage(event, DateTime.utc_now(:microsecond))
    |> Ankole.Errors.reason()
    |> case do
      {:ok, %Signal{status: :queued, attempt_count: attempts} = current} when attempts >= 3 ->
        commit(
          key,
          current,
          %{
            action: "NOOP",
            authority: "NONE",
            reason: "Ambient classification failed after three attempts."
          }
        )

      {:ok, %Signal{status: :queued} = current} ->
        {:ok, :deferred, current}

      {:ok, _current} ->
        {:ok, :settled}

      error ->
        error
    end
  end

  @doc false
  def retry_in_tx(repo, key, event, now) do
    with :ok <- Admission.authorize_new_work_in_tx(repo, event),
         :ok <- Queue.lock_session_in_tx(repo, key.agent_uid, key.session_id) do
      case Ankole.Signals.lock_signal_in_tx(repo, event.id) do
        %Signal{status: :queued} = current ->
          Ankole.Signals.transition_in_tx(repo, current, :retry_triage, %{
            available_at: DateTime.add(now, 30)
          })

        %Signal{} = current ->
          {:ok, current}
      end
    end
  end
end
