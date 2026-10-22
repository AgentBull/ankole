defmodule Ankole.Sessions.AmbientTriage do
  @moduledoc "Classifies ambient input before a foreground turn is admitted."
  require Ash.Query

  alias Ankole.AIGateway
  alias Ankole.AIAgent.TokenQuota
  alias Ankole.Repo

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

  def run(key, event) do
    now = DateTime.utc_now(:microsecond)

    with {:ok, %{status: :ambient_fresh, signal: current}} <- Ambient.resolve(event, now) do
      case AmbientJudgment
           |> Ash.Query.filter(signal_id == ^current.id)
           |> Ankole.Ash.read_one!() do
        %AmbientJudgment{} = judgment -> result(current, judgment)
        nil -> classify(key, current)
      end
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
               Ambient.candidates_in_tx(Repo, event)
             )
         },
         {:ok, attrs} <- recognize(observation) do
      commit(key, event, attrs)
    else
      {:error, {:model_profile_unavailable, profile, reason}} ->
        complete_without_model(
          key,
          event,
          "The ambient model profile is unavailable.",
          %{status: :model_profile_unavailable, profile: profile, profile_error: reason}
        )

      {:error, {:agent_token_quota_exceeded, window}} ->
        complete_without_model(
          key,
          event,
          "The Agent has used its token quota for the current period.",
          %{status: :agent_token_quota_exceeded, token_quota: window}
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
        result(Repo.get!(Signal, event.id), judgment)

      {:error, {:ambient_stale, _reason}} ->
        Ambient.resolve(event, DateTime.utc_now(:microsecond))

      error ->
        error
    end
  end

  defp result(event, %{action: action}) when action in ["FOREGROUND_REPLY", "NEW_WORK"],
    do: {:ok, %{status: :ambient_ready, signal: event}}

  defp result(event, _judgment), do: {:ok, %{status: :completed, signal: event}}

  defp complete_without_model(key, event, reason, outcome) do
    with {:ok, %{status: :completed} = result} <-
           commit(
             key,
             event,
             %{
               action: "NOOP",
               authority: "NONE",
               reason: reason
             }
           ) do
      {:ok,
       result
       |> Map.merge(outcome)
       |> Map.merge(%{posted: %Ankole.Conversations.PostResult{}, notice_error: nil})}
    end
  end

  defp retry(key, event) do
    Repo.transact(fn repo ->
      with :ok <- Admission.authorize_new_work_in_tx(repo, event),
           :ok <- Queue.lock_session_in_tx(repo, key.agent_uid, key.session_id) do
        case Ankole.Signals.lock_signal_in_tx(repo, event.id) do
          %Signal{status: :queued} = current ->
            now = DateTime.utc_now(:microsecond)

            current
            |> Ankole.Ash.update(:retry_triage, %{
              available_at: DateTime.add(now, 30)
            })

          %Signal{} = current ->
            {:ok, current}
        end
      end
    end)
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
        {:ok, %{status: :deferred, signal: current}}

      {:ok, current} ->
        {:ok, %{status: :completed, signal: current}}

      error ->
        error
    end
  end
end
