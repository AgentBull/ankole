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

  alias Ankole.AuthZ
  alias Ankole.Setup.Config

  @doc """
  Grants root admin to `principal_uid` and marks setup complete.
  """
  @spec complete_with_root_admin(String.t()) :: {:ok, map()} | {:error, term()}
  def complete_with_root_admin(principal_uid) do
    with {:ok, root} <- AuthZ.root_init_admin(principal_uid),
         {:ok, true} <- Config.put_completed(true),
         :ok <- Config.delete_bootstrap_activation_code() do
      {:ok, root}
    end
  end
end
