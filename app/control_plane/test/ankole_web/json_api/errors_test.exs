defmodule AnkoleWeb.JSONAPI.ErrorsTest do
  @moduledoc "Checks the JSON:API errors of the declared Ankole error vocabulary."
  use ExUnit.Case, async: true

  alias Ankole.Errors.Framework.{NestedOperation, TransactionRequired}
  alias Ankole.Errors.Invalid.{NotFound, Rejected, Stale, StatusTransition}

  defp render(error) do
    [rendered] =
      AshJsonApi.Error.to_json_api_errors(nil, nil, Ash.Error.to_error_class(error), :get)

    {rendered.status_code, rendered.code, rendered.detail}
  end

  test "conflicts, missing targets, and rejections use the Console error codes" do
    conflict =
      {409, "conflict",
       "the resource changed or does not permit this change; reload it and try again"}

    assert render(Stale.exception(resource: __MODULE__)) == conflict
    assert render(StatusTransition.exception(from: :queued, to: :done)) == conflict

    assert render(NotFound.exception(resource: __MODULE__)) ==
             {404, "not_found", "the resource was not found"}

    for {reason, code} <- [
          {:tenant_slug_taken, "tenant_slug_taken"},
          {{:library_managed, "skill"}, "library_managed"},
          {"free text", "rejected"}
        ] do
      assert render(Rejected.exception(reason: reason)) ==
               {422, code, "the domain operation was rejected"}
    end
  end

  test "framework errors give a generic server error without internal terms" do
    for error <- [
          NestedOperation.exception(resource: __MODULE__, action: :run),
          TransactionRequired.exception(operation: :claim_in_tx)
        ] do
      assert {500, "something_went_wrong", detail} = render(error)
      refute detail =~ "AnkoleWeb"
      refute detail =~ "claim_in_tx"
    end
  end
end
