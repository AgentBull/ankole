defmodule Ankole.WorkFixtures do
  @moduledoc false

  def applet_job(uid, attrs \\ %{}) do
    actor = Ankole.PrincipalsFixtures.actor_fixture(uid)

    owner =
      if actor.principal.type == :agent do
        Ankole.PrincipalsFixtures.human_fixture().principal
        |> Ankole.PrincipalsFixtures.actor_fixture()
      else
        actor
      end

    {:ok, page} = Ankole.Pod.Pages.create(owner, %{type: "applet"})

    if actor.principal.uid != owner.principal.uid do
      {:ok, _} =
        Ankole.Pod.PagesFixtures.set_sharing(owner.principal.uid, page.id, %{
          grants: [%{principal_uid: actor.principal.uid, role: "edit"}]
        })
    end

    Ankole.FilesFixtures.publish_applet_fixture(
      %{actor: owner, page: page},
      "export default { actions: { work: { idempotent: true, handler: ctx => ctx.signal.data } } }"
    )

    {:ok, job} =
      Ankole.AutomationJobs.create_applet_job(
        actor,
        page.id,
        "work",
        Map.merge(%{authorization_kind: "service"}, attrs)
      )

    job
  end

  def dispatch_job_in_tx(job, event) do
    alias Ankole.{AutomationJobs, Signals}
    reference = "webhook-endpoint://#{Ash.UUIDv7.generate()}"

    # Set up a real source Binding, then use the same admission and delivery
    # protocol as schedule/webhook producers. No alternate Run constructor.
    with :ok <- Ankole.Principals.WorkAccess.lock_authorizers_in_tx([job]),
         _ <- AutomationJobs.lock_job_in_tx(job.id),
         :ok <-
           Signals.SourceBindings.put_in_tx(
             reference,
             nil,
             nil,
             job.id
           ),
         {:ok, plan} <- Signals.Dispatch.prepare(reference, event),
         {:ok, plan} <- Signals.Dispatch.lock_in_tx(plan),
         {:ok, result} <- Signals.Dispatch.deliver_in_tx(plan) do
      case result.receipts do
        [receipt] ->
          {:ok,
           %{
             status: :queued,
             automation_job_run: AutomationJobs.get_run_record(receipt.automation_job_run_id)
           }}

        [] ->
          {:ok, %{status: :skipped}}
      end
    end
  end

  def service_source(agent_uid) do
    id = Ecto.UUID.generate()
    now = DateTime.utc_now(:microsecond)

    {:ok, event} =
      Ankole.Repo.transact(fn ->
        with {:ok, event} <-
               Ankole.Signals.accept_in_tx(%{
                 source: "test://work",
                 id: id,
                 type: "test.work",
                 time: now,
                 target: %{agent_uid: agent_uid, session_id: "test:work:#{id}"},
                 sender: agent_uid,
                 authorization: Ankole.Principals.WorkAccess.service(),
                 data: %{}
               }) do
          Ankole.Sessions.Queue.mark_event_completed_in_tx(event, now)
        end
      end)

    event
  end
end
