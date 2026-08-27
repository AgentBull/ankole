defmodule Ankole.Setup.Completion do
  @moduledoc """
  The one irreversible transition from an authenticated first-setup Principal
  to a completed installation.

  Every setup-completing path (OIDC, Local Password) authenticates its
  Principal its own way, then hands the resulting `principal_uid` here for the
  shared tail: claim root admin, mark setup complete, and delete the
  activation code. The caller must have already confirmed setup was not
  already complete before calling — this module does not re-check that, so
  that the single completion check stays at each caller's own gate.
  """

  alias Ankole.AppConfigure
  alias Ankole.AuthZ
  alias Ankole.Repo
  alias Ankole.Setup.Config

  @doc """
  Grants root admin to `principal_uid` and marks setup complete.

  The root claim and the completion flag commit in one transaction, so a
  failed claim can never leave the installation marked complete and a failed
  flag write can never leave a root grant behind. Activation-code deletion
  stays outside: a leftover code is inert once setup is complete, and
  bootstrap deletes it on the next start.
  """
  @spec complete_with_root_admin(String.t(), [String.t()]) :: {:ok, map()} | {:error, term()}
  def complete_with_root_admin(principal_uid, brain_packs \\ []) do
    transact_result =
      Repo.transact(fn repo ->
        with {:ok, root} <- AuthZ.root_init_admin(principal_uid, repo),
             :ok <- materialize_brain_packs(repo, brain_packs),
             {:ok, completed_write} <- Config.put_completed_in_tx(repo, true) do
          {:ok, {root, completed_write}}
        end
      end)

    with {:ok, {root, completed_write}} <- transact_result,
         {:ok, _completed} <- AppConfigure.cache_committed_write(completed_write),
         :ok <- Config.delete_bootstrap_activation_code() do
      {:ok, root}
    end
  end

  # The Brain schema selection materializes inside the completion
  # transaction: a failed materialization rolls back the completed flag. A
  # repeated first-admin claim finds the packs installed and continues.
  defp materialize_brain_packs(repo, brain_packs) do
    case Ankole.Brain.SchemaPacks.install_packs(brain_packs, repo: repo) do
      {:ok, _result} -> :ok
      {:error, _reason} = error -> error
    end
  end
end
