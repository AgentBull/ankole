defmodule Ankole.AIAgent.Operations.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.AIAgent.Operations`.
  """
  use Ash.Resource.Actions.Implementation

  alias Ankole.AIAgent.{ModelProfiles, TokenQuota}

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:put_token_quota, input, _context),
    do: input.arguments |> TokenQuota.put_locked() |> Ankole.Errors.wrap()

  defp action(:delete_token_quota, input, _context),
    do: input.arguments |> TokenQuota.delete_locked() |> Ankole.Errors.wrap()

  defp action(:reset_token_quota, input, _context),
    do: input.arguments |> TokenQuota.reset_locked() |> Ankole.Errors.wrap()

  defp action(:put_model_profile, input, _context),
    do: input.arguments |> ModelProfiles.put_profile_locked() |> Ankole.Errors.wrap()

  defp action(:put_provider_hosted_capabilities, input, _context),
    do: input.arguments |> ModelProfiles.put_provider_hosted_locked() |> Ankole.Errors.wrap()
end
