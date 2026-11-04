defmodule Ankole.AutomationJobs.AttemptAccess do
  @moduledoc "Checks the live Automation Job fence and constructs its Pod actor."
  require Ash.Query
  alias Ankole.AuthZ.Actor
  alias Ankole.AutomationJobs.AttemptRef
  alias Ankole.AutomationJobs.Schemas.{Job, Run}

  def authorize_actor_in_tx(ref, ctx, opts \\ [])

  def authorize_actor_in_tx(
        %AttemptRef{principal_uid: uid} = ref,
        %{
          principal_uid: uid
        },
        opts
      ) do
    with %Job{} <- get(Job, ref.job_id, opts),
         %Run{status: :running, automation_job_id: job_id, attempt_id: attempt_id} <-
           get(Run, ref.run_id, opts),
         true <- job_id == ref.job_id and attempt_id == ref.attempt_id,
         {:ok, principal} <- Ankole.Principals.get_principal(uid) do
      {:ok,
       Actor.new(principal, turn_authority: {ref, uid}, authn: %{"surface" => "applet_action"})}
    else
      {:error, _} = error -> error
      _ -> {:error, :automation_job_attempt_not_active}
    end
  end

  def authorize_actor_in_tx(_, _, _), do: {:error, :automation_job_attempt_not_active}

  defp get(schema, id, opts) do
    query = Ash.Query.filter(schema, id == ^id)

    if Keyword.get(opts, :lock, true) do
      table = if schema == Job, do: "automation_jobs", else: "automation_job_runs"

      query
      |> Ash.Query.lock(:for_update)
      |> Ankole.Ash.read_one!(lock_identity: {table, id})
    else
      Ankole.Ash.read_one!(query)
    end
  end
end
