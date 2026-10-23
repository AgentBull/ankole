defmodule Ankole.Errors.Invalid.Conflict do
  @moduledoc """
  Carries a domain rejection that conflicts with the current state, for example
  a provider that Agents still use or a protected tenant.

  It is a `Ankole.Errors.Invalid.Rejected` with another meaning: the reason
  stays an atom or a tuple, and `Ankole.Errors.reason/1` gives it back to
  domain code. `Ankole.Errors.wrap/2` makes it from a rejection and can add
  `detail` and `details`. The v2 JSON:API error has status 409, the code of the
  reason (the rule of `Ankole.Errors.Invalid.Rejected.code/1`), and `detail`
  and `meta.details`. `Ankole.Errors.Invalid.Stale` and
  `Ankole.Errors.Invalid.StatusTransition` stay the errors of an optimistic lock
  and of a state machine.
  """

  use Splode.Error, fields: [:reason, :detail, details: []], class: :invalid

  def message(_error), do: "The domain operation conflicts with the current state"

  defimpl AshJsonApi.ToJsonApiError do
    def to_json_api_error(error),
      do: %AshJsonApi.Error{
        id: Ash.UUID.generate(),
        status_code: 409,
        code: Ankole.Errors.Invalid.Rejected.code(error.reason),
        title: "Conflict",
        detail: error.detail || "the domain operation conflicts with the current state",
        meta: if(error.details == [], do: :undefined, else: %{details: error.details})
      }
  end
end
