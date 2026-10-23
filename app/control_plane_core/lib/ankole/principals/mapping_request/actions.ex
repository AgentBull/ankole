defmodule Ankole.Principals.MappingRequest.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.Principals.MappingRequest`.
  """
  use Ash.Resource.Actions.Implementation

  alias Ankole.Principals.MappingRequest

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:record_observation, input, _context) do
    Ankole.Repo
    |> Ankole.Principals.MappingRequests.record_observation_in_tx(input.arguments.attrs)
    |> Ankole.Errors.wrap()
  end

  defp action(:bind_request, input, _context) do
    Ankole.Principals.MappingRequests.bind_request_in_tx(
      Ankole.Repo,
      input.arguments.id,
      input.arguments.principal_uid
    )
    |> Ankole.Errors.not_found(
      [:not_found, :principal_not_found],
      MappingRequest
    )
    |> Ankole.Errors.wrap(&Ankole.Principals.describe_refusal/1)
  end

  defp action(:bind_subject, input, _context) do
    Ankole.Principals.MappingRequests.bind_subject_in_tx(
      Ankole.Repo,
      input.arguments.principal_uid,
      Map.take(input.arguments, [:provider, :external_id])
    )
    |> Ankole.Errors.not_found(
      [:not_found, :principal_not_found],
      MappingRequest
    )
    |> Ankole.Errors.wrap(&Ankole.Principals.describe_refusal/1)
  end
end
