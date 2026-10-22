defmodule Ankole.AshResourceConstraintsTest do
  use Ankole.DataCase, async: false

  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.Principals.Principal
  alias Ankole.Workflow.Schemas.AgentCall
  alias Ankole.Workflow.Schemas.Run

  @moduletag sandbox: false

  setup %{tenant: tenant} do
    on_exit(fn -> Repo.with_tenant(tenant.id, fn -> cleanup_tenant!(tenant) end) end)

    {:ok, principal} =
      Repo.transact(fn _repo ->
        Ankole.Ash.create(Principal, :create_in_tx, %{
          uid: "constraint-agent-#{System.unique_integer([:positive])}",
          type: :agent,
          display_name: "Constraint test Agent"
        })
      end)

    {:ok, agent_uid: principal.uid}
  end

  for {kind, foreign_key} <- [job: :source_signal_id, run: :source_signal_id, call: :run_id] do
    test "#{kind} returns a field error when its database foreign key rejects creation", ctx do
      {resource, action, attrs} = input(unquote(kind), ctx.agent_uid)

      missing =
        if unquote(foreign_key) == :run_id, do: 9_007_199_254_740_990, else: Ecto.UUID.generate()

      assert {:error, %Ash.Error.Invalid{} = error} =
               Repo.transact(fn _repo ->
                 Ankole.Ash.create(
                   resource,
                   action,
                   Map.put(attrs, unquote(foreign_key), missing)
                 )
               end)

      assert %{path: unquote(to_string(foreign_key)), message: "does not exist"} in Ankole.Ash.validation_details(
               error
             )
    end
  end

  for {kind, unique_field} <- [job: "agent_uid", run: "agent_uid", call: "run_id"] do
    test "#{kind} preserves its unique index under two concurrent creates", ctx do
      {resource, action, attrs} = input(unquote(kind), ctx.agent_uid)
      second = if unquote(kind) == :job, do: job_id(attrs), else: attrs
      parent = self()

      tasks =
        Enum.map([attrs, second], fn attrs ->
          Task.async(fn ->
            Repo.with_tenant(ctx.tenant.id, fn ->
              Repo.transact(fn _repo ->
                send(parent, {:ready, self()})

                receive do
                  :create -> Ankole.Ash.create(resource, action, attrs)
                end
              end)
            end)
          end)
        end)

      for task <- tasks, do: assert_receive({:ready, pid} when pid == task.pid, 5_000)
      Enum.each(tasks, &send(&1.pid, :create))
      results = Enum.map(tasks, &Task.await(&1, 5_000))

      assert [{:ok, _record}] = Enum.filter(results, &match?({:ok, _}, &1))

      assert [{:error, %Ash.Error.Invalid{} = error}] =
               Enum.filter(results, &match?({:error, _}, &1))

      assert %{path: unquote(unique_field), message: "has already been taken"} in Ankole.Ash.validation_details(
               error
             )
    end
  end

  for {kind, field} <- [job: "continued_from_job_id", run: "completed_at", call: "wake_at"] do
    test "#{kind} returns its database check constraint as a field error", ctx do
      {resource, action, attrs} = input(unquote(kind), ctx.agent_uid)

      invalid = invalid_check_attrs(unquote(kind), attrs)

      assert {:error, %Ash.Error.Invalid{} = error} =
               Repo.transact(fn _repo ->
                 # Inject invalid storage state after action input validation to test the native CHECK.
                 resource
                 |> Ankole.Ash.for_create(action, attrs)
                 |> Ash.Changeset.force_change_attributes(invalid)
                 |> Ankole.Ash.create()
               end)

      assert %{path: unquote(field), message: "is invalid"} in Ankole.Ash.validation_details(
               error
             )
    end
  end

  for field <- [:owner_session_id, :source_tool_call_id] do
    test "run maps the native nonblank CHECK for #{field}", ctx do
      {resource, action, attrs} = input(:run, ctx.agent_uid)

      assert {:error, %Ash.Error.Invalid{} = error} =
               Repo.transact(fn _repo ->
                 changeset = Ankole.Ash.for_create(resource, action, attrs)

                 # Normal input trims blanks to nil. Inject the stored value to reach the CHECK.
                 changeset = %{
                   changeset
                   | attributes: Map.put(changeset.attributes, unquote(field), " ")
                 }

                 Ankole.Ash.create(changeset)
               end)

      assert %{path: unquote(to_string(field)), message: "is invalid"} in Ankole.Ash.validation_details(
               error
             )
    end
  end

  defp input(:job, agent_uid) do
    attrs =
      %{
        authorization_kind: "service",
        agent_uid: agent_uid,
        owner_session_id: "constraint-parent",
        source_tool_call_id: "constraint-create",
        title: "Constraint test",
        task: "Keep the database constraint.",
        reply_route: %{},
        model_profile: "coding"
      }
      |> job_id()

    {Job, :create_job, attrs}
  end

  defp input(:run, agent_uid) do
    {Run, :create_run,
     %{
       authorization_kind: "service",
       agent_uid: agent_uid,
       owner_session_id: "constraint-parent",
       source_tool_call_id: "constraint-create",
       title: "Constraint test",
       script: "return 'done';",
       args: %{},
       concurrency: 1,
       max_agent_calls: 1,
       reply_route: %{}
     }}
  end

  defp input(:call, agent_uid) do
    {resource, action, attrs} = input(:run, agent_uid)
    {:ok, run} = Repo.transact(fn _repo -> Ankole.Ash.create(resource, action, attrs) end)

    {AgentCall, :create_call,
     %{run_id: run.id, agent_uid: agent_uid, call_seq: 0, arguments: %{"prompt" => "Check."}}}
  end

  defp job_id(attrs) do
    %{rows: [[id]]} =
      Repo.query!("SELECT nextval(pg_get_serial_sequence('background_agent_jobs', 'id'))")

    Map.merge(attrs, %{id: id, workspace_owner_job_id: id})
  end

  defp invalid_check_attrs(:job, attrs), do: %{continued_from_job_id: attrs.id}
  defp invalid_check_attrs(:run, _attrs), do: %{completed_at: DateTime.utc_now(:microsecond)}

  defp invalid_check_attrs(:call, _attrs),
    do: %{wake_kind: :sleep, wake_at: DateTime.utc_now(:microsecond)}
end
