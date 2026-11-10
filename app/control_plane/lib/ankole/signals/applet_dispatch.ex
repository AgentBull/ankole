defmodule Ankole.Signals.AppletDispatch do
  @moduledoc "Same-page synchronous calls, durable triggers, and authorized Run progress."
  alias Ankole.{AutomationJobs, Pod, Repo}
  alias Ankole.Signals.Dispatch
  alias Ankole.Principals.WorkAccess

  def dispatch(context, page, actor, caller, :wait_result, [request]) when is_map(request) do
    remaining = context["deadline"] - System.monotonic_time(:millisecond)

    with true <- remaining > 0,
         {:ok, _} <- Pod.authorize_applet(actor, page.id, "node_view"),
         do: Pod.call_applet_function(caller, page.id, request, context),
         else: (
           false -> {:error, :handler_timeout}
           error -> error
         )
  end

  def dispatch(context, page, actor, _caller, :wait_accepted, [%{"targetJobId" => id} = request]) do
    with {:ok, id} <- Ankole.ModelIntegerID.parse(id),
         do: accept(context, page, actor, id, envelope(context, page, request), 3)
  end

  def dispatch(context, page, actor, caller, :fire_and_forget, [request]) when is_map(request) do
    with {:ok, _} <- Pod.authorize_applet(actor, page.id, "node_contribute"),
         {:ok, authorization} <- authorization(context, caller),
         {:ok, result} <-
           Dispatch.emit(reference(context, page), envelope(context, page, request),
             authorization: authorization,
             attempt_authority: attempt_authority(actor)
           ) do
      {:ok, %{accepted: true, signalId: result.signal_id, delivered: result.receipts != []}}
    end
  end

  def dispatch(_, _, _, _, _, _), do: {:error, :invalid_request}

  defp accept(context, page, actor, id, signal, retries) do
    with {:ok, job} when not is_nil(job) <- AutomationJobs.get_automation_job(id),
         :ok <- AutomationJobs.authorize_applet_job(actor, job, page.id, "node_contribute"),
         {:ok, key} <- AutomationJobs.prepare_applet_job(job, signal) do
      result =
        Repo.transact_top_level(fn ->
          with :ok <- WorkAccess.check_in_tx(job),
               locked when not is_nil(locked) <- lock_target(job, context),
               :ok <- Ankole.AuthZ.authorize_turn_in_tx(attempt_authority(actor)),
               true <- locked.status == :active,
               :ok <- unchanged_job(locked, job),
               :ok <-
                 AutomationJobs.authorize_applet_job(actor, locked, page.id, "node_contribute"),
               {:ok, result} <-
                 AutomationJobs.enqueue_locked_in_tx(locked, signal,
                   concurrency_key: key,
                   signal_id: signal["signal_id"],
                   causation_id: signal["causation_id"],
                   correlation_id: signal["correlation_id"]
                 ) do
            {:ok,
             %{accepted: true, runId: result.automation_job_run.id, coalesced: result.coalesced}}
          else
            false -> {:error, :automation_job_not_active}
            nil -> {:error, :not_found}
            error -> error
          end
        end)

      if result == {:error, :automation_job_changed} and retries > 0,
        do: accept(context, page, actor, id, signal, retries - 1),
        else: result
    else
      {:ok, nil} -> {:error, :not_found}
      error -> error
    end
  end

  defp unchanged_job(job, job), do: :ok
  defp unchanged_job(_locked, _prepared), do: {:error, :automation_job_changed}

  defp authorization(%{"job" => %{"id" => id}}, _caller) do
    with {:ok, job} when not is_nil(job) <- AutomationJobs.get_automation_job(id),
         do: {:ok, WorkAccess.fields(job)},
         else: (_ -> {:error, :automation_job_attempt_not_active})
  end

  defp authorization(_context, caller),
    do: {:ok, WorkAccess.from_sender(Ankole.AuthZ.Actor.uid(caller))}

  defp lock_target(job, context) do
    [job.id, get_in(context, ["job", "id"])]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Map.new(&{&1, AutomationJobs.lock_job_in_tx(&1)})
    |> Map.get(job.id)
  end

  defp attempt_authority(%{turn_authority: {%Ankole.AutomationJobs.AttemptRef{}, _} = authority}),
    do: authority

  defp attempt_authority(_), do: nil

  defp reference(%{"job" => %{"id" => id}}, _page), do: "job://#{id}"
  defp reference(_context, page), do: "applet://#{page.id}"

  defp envelope(context, page, request) do
    id = Ash.UUIDv7.generate()

    %{
      "id" => request["id"] || id,
      "signal_id" => id,
      "type" => request["type"] || "applet.action.requested",
      "source" => "ankole:" <> String.replace(reference(context, page), "://", ":"),
      "data" => request["data"] || %{},
      "time" => DateTime.to_iso8601(DateTime.utc_now()),
      "causation_id" => get_in(context, ["signal", "signal_id"]),
      "correlation_id" => get_in(context, ["signal", "correlation_id"]) || id
    }
    |> Map.merge(Map.take(request, ["subject"]))
  end
end
