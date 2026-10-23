defmodule Ankole.Principals.Principal.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.Principals.Principal`.
  """
  use Ash.Resource.Actions.Implementation

  alias Ankole.Principals.Principal

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:create_human, input, _context) do
    Ankole.Errors.wrap(Ankole.Principals.create_human_in_tx(Ankole.Repo, input.arguments.attrs))
  end

  defp action(:create_agent, input, _context) do
    Ankole.Errors.wrap(Ankole.Principals.create_agent_in_tx(Ankole.Repo, input.arguments.attrs))
  end

  defp action(:enable_agent, input, _context),
    do: Ankole.Errors.wrap(Ankole.Principals.enable_agent_in_tx(Ankole.Repo, input.arguments.uid))

  defp action(:delete_agent, input, _context),
    do: Ankole.Errors.wrap(Ankole.Principals.delete_agent_in_tx(Ankole.Repo, input.arguments.uid))

  defp action(:upsert_platform_subject_human, input, _context) do
    Ankole.Repo
    |> Ankole.Principals.upsert_platform_subject_human_in_tx(input.arguments.attrs)
    |> Ankole.Errors.wrap()
  end

  defp action(:update_human, input, _context) do
    Ankole.Principals.update_human_in_tx(Ankole.Repo, input.arguments)
    |> Ankole.Errors.not_found([:not_found, :principal_not_found], Principal)
    |> Ankole.Errors.wrap(&Ankole.Principals.describe_refusal/1)
  end

  defp action(:create_local_user, input, _context) do
    Ankole.Principals.create_local_user_in_tx(Ankole.Repo, input.arguments)
    |> Ankole.Errors.wrap(&Ankole.Principals.describe_refusal/1)
  end

  defp action(:update_agent, input, _context) do
    Ankole.Principals.update_agent_in_tx(
      Ankole.Repo,
      input.arguments.uid,
      input.arguments.attrs
    )
    |> Ankole.Errors.wrap()
  end

  defp action(:recover_admin, input, _context) do
    Ankole.Principals.HumanAccess.recover_admin_in_tx(
      Ankole.Repo,
      input.arguments.uid,
      input.arguments.operator,
      input.arguments.reason
    )
    |> Ankole.Errors.wrap()
  end

  defp action(:restrict, input, _context) do
    Ankole.Principals.HumanAccess.restrict_in_tx(
      Ankole.Repo,
      input.arguments.uid,
      input.arguments.attrs
    )
    |> Ankole.Errors.wrap()
  end

  defp action(:verify_provider_recovery, input, _context) do
    Ankole.Principals.HumanAccess.verify_provider_recovery_in_tx(
      Ankole.Repo,
      input.arguments.uid,
      input.arguments.provider_id,
      input.arguments.operation_id
    )
    |> Ankole.Errors.wrap()
  end

  defp action(:clear_restriction, input, _context) do
    Ankole.Principals.HumanAccess.clear_restriction_in_tx(
      Ankole.Repo,
      input.arguments.uid,
      input.arguments.restriction_id,
      input.arguments.actor,
      input.arguments.reason,
      input.arguments.operation_id
    )
    |> Ankole.Errors.wrap()
  end

  defp action(:restore, input, _context) do
    Ankole.Principals.HumanAccess.restore_in_tx(
      Ankole.Repo,
      input.arguments.uid,
      input.arguments.review_fingerprint,
      input.arguments.actor,
      input.arguments.reason,
      input.arguments.operation_id
    )
    |> Ankole.Errors.wrap()
  end

  defp action(:classify_work, input, _context) do
    Ankole.Principals.WorkAccess.classify_in_tx(
      Ankole.Repo,
      input.arguments.kind,
      input.arguments.id,
      input.arguments.human_uid,
      input.arguments.actor,
      input.arguments.reason
    )
    |> Ankole.Errors.wrap()
  end

  defp action(:cleanup_work, input, _context) do
    Ankole.Principals.WorkCleanup.cleanup_in_tx(
      Ankole.Repo,
      input.arguments.uid,
      input.arguments.version
    )
    |> Ankole.Errors.wrap()
  end
end
