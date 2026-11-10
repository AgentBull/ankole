defmodule Ankole.ErrorsTest do
  use ExUnit.Case, async: true

  alias Ankole.Errors
  alias Ankole.Errors.Invalid.{Conflict, NotFound, Rejected, Stale, StatusTransition}
  alias AshStateMachine.Errors.NoMatchingTransition

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
