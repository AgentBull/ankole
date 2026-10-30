defmodule Ankole.ErrorsTest do
  use ExUnit.Case, async: true

  alias Ankole.Errors
  alias Ankole.Errors.Invalid.{Conflict, NotFound, Rejected, Stale, StatusTransition}
  alias AshStateMachine.Errors.NoMatchingTransition

  test "shape/2 gives the declared exceptions and keeps other errors" do
    changeset = %Ash.Changeset{resource: TenantIsolationFixture.Probe}

    assert %Stale{resource: TenantIsolationFixture.Probe, filter: %{id: 1}} =
             Errors.shape(changeset, Ash.Error.Changes.StaleRecord.exception(filter: %{id: 1}))

    transition = NoMatchingTransition.exception(field: :status, old_state: :done, target: :queued)

    assert %StatusTransition{
             resource: TenantIsolationFixture.Probe,
             field: :status,
             from: :done,
             to: :queued
           } = Errors.shape(changeset, transition)

    required = Ash.Error.Changes.Required.exception(field: :name)
    assert Errors.shape(changeset, required) == required

    class = Ash.Error.Invalid.exception(errors: [transition, required])

    assert %Ash.Error.Invalid{errors: [%StatusTransition{}, ^required]} =
             Errors.shape(changeset, class)
  end

  test "wrap/1 gives a domain reason as a declared rejection" do
    assert {:error, %Rejected{reason: {:library_managed, "skill"}}} =
             Errors.wrap({:error, {:library_managed, "skill"}})

    stale = Stale.exception(resource: TenantIsolationFixture.Probe)
    assert Errors.wrap({:error, stale}) == {:error, stale}
    assert Errors.wrap({:ok, :value}) == {:ok, :value}
    assert Errors.wrap(:ok) == :ok
  end

  test "wrap/2 adds the operator text, makes a conflict, or replaces the rejection" do
    describe = fn
      :invalid_config -> {"The YAML is invalid", [%{path: "config", line: 3}]}
      :in_use -> {:conflict, "Agents use it", []}
      :missing -> NotFound.exception(resource: TenantIsolationFixture.Probe)
      _other -> nil
    end

    assert {:error,
            %Rejected{
              reason: :invalid_config,
              detail: "The YAML is invalid",
              details: [%{path: "config", line: 3}]
            }} = Errors.wrap({:error, :invalid_config}, describe)

    assert {:error, %Conflict{reason: :in_use, detail: "Agents use it"}} =
             Errors.wrap({:error, :in_use}, describe)

    assert {:error, %NotFound{resource: TenantIsolationFixture.Probe}} =
             Errors.wrap({:error, :missing}, describe)

    assert {:error, %Rejected{reason: :other, detail: nil}} =
             Errors.wrap({:error, :other}, describe)

    assert Errors.wrap({:ok, 1}, describe) == {:ok, 1}
  end

  test "a rejection and a conflict give their reason code to the JSON:API error" do
    assert %AshJsonApi.Error{
             status_code: 422,
             code: "invalid_config",
             detail: "Bad",
             meta: %{details: [%{path: "config"}]}
           } =
             AshJsonApi.ToJsonApiError.to_json_api_error(
               Rejected.exception(
                 reason: :invalid_config,
                 detail: "Bad",
                 details: [%{path: "config"}]
               )
             )

    assert %AshJsonApi.Error{status_code: 409, code: "in_use", meta: :undefined} =
             AshJsonApi.ToJsonApiError.to_json_api_error(
               Conflict.exception(reason: {:in_use, "p"})
             )
  end

  test "rollback_result/1 gives a rolled-back changeset as its class and keeps other results" do
    changeset =
      %Ash.Changeset{resource: TenantIsolationFixture.Probe}
      |> Ash.Changeset.add_error(Ash.Error.Changes.StaleRecord.exception(filter: %{id: 1}))

    assert {:error, %Ash.Error.Invalid{errors: [%Stale{}]}} =
             Errors.rollback_result({:error, changeset})

    # A generic action rolls back with its declared rejection; the class stays.
    rejected = Ash.Error.to_error_class(Rejected.exception(reason: :job_not_found))
    assert Errors.rollback_result({:error, rejected}) == {:error, rejected}
    assert Errors.rollback_result({:error, :reason}) == {:error, :reason}
    assert Errors.rollback_result({:ok, 1}) == {:ok, 1}
  end

  test "reason/1 gives domain code its reason and keeps other failures" do
    for {error, reason} <- [
          {Ash.Error.Forbidden.exception([]), :forbidden},
          {Rejected.exception(reason: :job_not_found), :job_not_found},
          {Conflict.exception(reason: :worker_provider_in_use), :worker_provider_in_use},
          {Stale.exception([]), :stale},
          {Ash.Error.Changes.StaleRecord.exception([]), :stale},
          {NotFound.exception(id: 1), :not_found},
          {StatusTransition.exception(from: :done, to: :queued),
           {:invalid_status_transition, :done, :queued}},
          {NoMatchingTransition.exception(old_state: :done, target: :queued),
           {:invalid_status_transition, :done, :queued}}
        ] do
      assert Errors.reason({:error, Ash.Error.to_error_class(error)}) == {:error, reason}
      assert Errors.reason({:error, error}) == {:error, reason}
    end

    validation = Ash.Error.to_error_class(Ash.Error.Changes.Required.exception(field: :name))
    assert Errors.reason({:error, validation}) == {:error, validation}
    assert Errors.reason({:error, :already_atom}) == {:error, :already_atom}
    assert Errors.reason({:ok, 1}) == {:ok, 1}
  end
end
