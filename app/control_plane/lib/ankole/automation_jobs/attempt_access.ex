defmodule Ankole.AutomationJobs.AttemptAccess do
  @moduledoc "Checks the live Automation Job fence and constructs its Pod actor."
  require Ash.Query
  alias Ankole.AuthZ.Actor
  alias Ankole.AutomationJobs.AttemptRef
  alias Ankole.AutomationJobs.Schemas.{Job, Run}
  alias Ankole.Principals.WorkAccess
  alias Ankole.Repo

  def authorize_actor(attempt, %{worker_id: uid} = ctx) do
    with {:ok, ref} <- AttemptRef.from_request(attempt, uid),
         do: Repo.transact_top_level(fn -> authorize_actor_in_tx(ref, ctx) end)
  end

  def authorize_actor_in_tx(%AttemptRef{agent_uid: uid} = ref, %{worker_id: uid}) do
    # Check the Human before the Job and Run rows.
    with %Job{} = snapshot <- Ankole.Ash.read_one!(Ash.Query.filter(Job, id == ^ref.job_id)),
         :ok <- WorkAccess.check_in_tx(snapshot),
         %Job{status: :active, agent_uid: ^uid} = job <- lock(Job, ref.job_id),
         %Run{status: :running, automation_job_id: job_id, attempt_id: attempt_id} <-
           lock(Run, ref.run_id),
         true <- job_id == ref.job_id and attempt_id == ref.attempt_id,
         {:ok, principal} <- Ankole.Principals.get_principal(uid),
         {:ok, human} <- human(job) do
      {:ok,
       Actor.new(principal,
         interactive_principal: human,
         turn_authority: {ref, uid},
         authn: %{"surface" => "automation_job"},
         interactive_authn: %{"surface" => "automation_job"}
       )}
    else
      {:error, _} = error -> error
      _ -> {:error, :automation_job_attempt_not_active}
    end
  end

  def authorize_actor_in_tx(_, _), do: {:error, :automation_job_attempt_not_active}

  defp human(%{authorization_kind: "human", human_uid: uid, human_access_version: version}) do
    case Ankole.Principals.get_principal(uid) do
      {:ok, %{type: :human, status: :active, access_version: ^version} = human} -> {:ok, human}
      _ -> {:error, :human_access_revoked}
    end
  end

  defp human(%{authorization_kind: "service"}), do: {:ok, nil}
  defp human(_), do: {:error, :work_authorization_review_required}

  defp lock(schema, id) do
    table = if schema == Job, do: "automation_jobs", else: "automation_job_runs"

    schema
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.lock(:for_update)
    |> Ankole.Ash.read_one!(lock_identity: {table, id})
  end
end
