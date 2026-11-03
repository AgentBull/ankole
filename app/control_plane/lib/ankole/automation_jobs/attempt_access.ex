defmodule Ankole.AutomationJobs.AttemptAccess do
  @moduledoc "Checks the live Automation Job fence and constructs its Pod actor."
  require Ash.Query
  alias Ankole.AuthZ.Actor
  alias Ankole.AutomationJobs.AttemptRef
  alias Ankole.AutomationJobs.Schemas.{Job, Run}
  alias Ankole.Repo

  def authorize_actor(attempt, %{worker_id: uid} = ctx) do
    with {:ok, ref} <- AttemptRef.from_request(attempt, uid),
         do: Repo.transact_top_level(fn -> authorize_actor_in_tx(ref, ctx) end)
  end

  def authorize_actor_in_tx(%AttemptRef{agent_uid: uid} = ref, %{worker_id: uid}) do
    with %Job{agent_uid: ^uid} <- lock(Job, ref.job_id),
         %Run{status: :running, automation_job_id: job_id, attempt_id: attempt_id} <-
           lock(Run, ref.run_id),
         true <- job_id == ref.job_id and attempt_id == ref.attempt_id,
         {:ok, principal} <- Ankole.Principals.get_principal(uid) do
      {:ok,
       Actor.new(principal,
         turn_authority: {ref, uid},
         authn: %{"surface" => "automation_job"}
       )}
    else
      {:error, _} = error -> error
      _ -> {:error, :automation_job_attempt_not_active}
    end
  end

  def authorize_actor_in_tx(%AttemptRef{agent_uid: nil, principal_uid: uid} = ref, %{
        principal_uid: uid
      }) do
    with %Job{executor_kind: :applet_function} <- lock(Job, ref.job_id),
         %Run{status: :running, automation_job_id: job_id, attempt_id: attempt_id} <-
           lock(Run, ref.run_id),
         true <- job_id == ref.job_id and attempt_id == ref.attempt_id,
         {:ok, principal} <- Ankole.Principals.get_principal(uid) do
      {:ok,
       Actor.new(principal, turn_authority: {ref, uid}, authn: %{"surface" => "applet_action"})}
    else
      {:error, _} = error -> error
      _ -> {:error, :automation_job_attempt_not_active}
    end
  end

  def authorize_actor_in_tx(_, _), do: {:error, :automation_job_attempt_not_active}

  defp lock(schema, id) do
    table = if schema == Job, do: "automation_jobs", else: "automation_job_runs"

    schema
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.lock(:for_update)
    |> Ankole.Ash.read_one!(lock_identity: {table, id})
  end
end
