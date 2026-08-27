defmodule Ankole.Principals.LocalCredentials do
  @moduledoc """
  Local email/password sign-in credentials for human Principals.

  The email on the human profile is the sign-in key; the credential row holds
  the Argon2id hash and the must-change flag. Principal creation seeds the
  first credential through `put_in_tx/4`; every later password change runs in
  this module's own transactions.
  """

  import Ecto.Query, warn: false

  alias Ankole.Kernel, as: NativeKernel
  alias Ankole.Principals
  alias Ankole.Principals.HumanUser
  alias Ankole.Principals.LocalCredential
  alias Ankole.Principals.Principal
  alias Ankole.Repo

  @local_password_min_length 6

  @doc """
  Returns the minimum accepted length for a local password.
  """
  @spec local_password_min_length() :: pos_integer()
  def local_password_min_length, do: @local_password_min_length

  @doc """
  Hashes and stores a caller-chosen local password for one human user.
  """
  @spec set_local_password(String.t(), String.t(), boolean()) ::
          {:ok, LocalCredential.t()} | {:error, term()}
  def set_local_password(uid, password, must_change_password)
      when is_boolean(must_change_password) do
    with {:ok, uid} <- Principals.normalize_uid(uid),
         :ok <- validate_local_password(password) do
      Repo.transact(fn repo ->
        with :ok <- ensure_local_login_human(repo, uid) do
          put_in_tx(repo, uid, password, must_change_password)
        end
      end)
    end
  end

  @doc """
  Completes a forced password change for one human user.

  The write locks the credential row and requires the verified credential
  version and the must-change flag to still match.
  """
  @spec complete_forced_password_change(String.t(), String.t(), non_neg_integer()) ::
          {:ok, LocalCredential.t()} | {:error, term()}
  def complete_forced_password_change(uid, new_password, credential_version) do
    with {:ok, uid} <- Principals.normalize_uid(uid),
         :ok <- validate_local_password(new_password) do
      Repo.transact(fn repo ->
        with %LocalCredential{must_change_password: true} = credential <-
               fetch_local_credential_for_update(repo, uid),
             true <- LocalCredential.version(credential) == credential_version do
          put_in_tx(repo, uid, new_password, false)
        else
          _no_matching_change -> {:error, :password_change_not_required}
        end
      end)
    end
  end

  @doc """
  Replaces one human user's local password with a generated initial password.
  """
  @spec reset_local_password(String.t(), boolean()) :: {:ok, String.t()} | {:error, term()}
  def reset_local_password(uid, must_change_password \\ true)
      when is_boolean(must_change_password) do
    with {:ok, uid} <- Principals.normalize_uid(uid) do
      initial_password = LocalCredential.generate_initial_password()

      Repo.transact(fn repo ->
        with :ok <- ensure_local_login_human(repo, uid),
             {:ok, _credential} <-
               put_in_tx(repo, uid, initial_password, must_change_password) do
          {:ok, initial_password}
        end
      end)
    end
  end

  @doc """
  Replaces the local password for the human user that owns one email address.
  """
  @spec reset_local_password_by_email(String.t()) ::
          {:ok, %{principal_uid: String.t(), initial_password: String.t()}} | {:error, term()}
  def reset_local_password_by_email(email) do
    with {:ok, %{principal: principal}} <- fetch_local_login(email),
         {:ok, initial_password} <- reset_local_password(principal.uid, true) do
      {:ok, %{principal_uid: principal.uid, initial_password: initial_password}}
    end
  end

  @doc """
  Loads the Principal, human profile, and local credential for one email.
  """
  @spec fetch_local_login(String.t()) ::
          {:ok,
           %{
             principal: Principal.t(),
             human_user: HumanUser.t(),
             credential: LocalCredential.t() | nil
           }}
          | {:error, :not_found}
  def fetch_local_login(email) do
    case Principals.normalize_email(email) do
      nil ->
        {:error, :not_found}

      normalized ->
        case Repo.one(local_login_query(normalized)) do
          nil -> {:error, :not_found}
          login -> {:ok, login}
        end
    end
  end

  # Principal creation seeds the first credential inside its own transaction.
  @doc false
  @spec put_in_tx(module(), String.t(), String.t(), boolean()) ::
          {:ok, LocalCredential.t()} | {:error, term()}
  def put_in_tx(repo, principal_uid, password, must_change_password) do
    case NativeKernel.argon2id_hash(password) do
      hash when is_binary(hash) ->
        attrs = %{
          principal_uid: principal_uid,
          password_hash: hash,
          must_change_password: must_change_password
        }

        case repo.get(LocalCredential, principal_uid) do
          %LocalCredential{} = credential ->
            credential
            |> LocalCredential.changeset(attrs)
            |> repo.update()

          nil ->
            %LocalCredential{}
            |> LocalCredential.changeset(attrs)
            |> repo.insert()
        end

      {:error, reason} ->
        {:error, {:password_hash_failed, reason}}
    end
  end

  defp validate_local_password(password) when is_binary(password) do
    case String.length(password) >= @local_password_min_length do
      true -> :ok
      false -> {:error, :password_too_short}
    end
  end

  defp validate_local_password(_password), do: {:error, :password_too_short}

  # The email is the local sign-in key, so a credential is only meaningful on
  # a human user row that has one. A missing human row splits into "no such
  # principal" (404 for callers) and "principal is not a human".
  defp ensure_local_login_human(repo, principal_uid) do
    case repo.get(HumanUser, principal_uid) do
      %HumanUser{email: email} when is_binary(email) ->
        :ok

      %HumanUser{} ->
        {:error, :email_missing}

      nil ->
        case repo.get(Principal, principal_uid) do
          %Principal{} -> {:error, :not_human}
          nil -> {:error, :not_found}
        end
    end
  end

  defp fetch_local_credential_for_update(repo, principal_uid) do
    repo.one(
      from credential in LocalCredential,
        where: credential.principal_uid == ^principal_uid,
        lock: "FOR UPDATE"
    )
  end

  defp local_login_query(email) do
    from human_user in HumanUser,
      join: principal in assoc(human_user, :principal),
      left_join: credential in LocalCredential,
      on: credential.principal_uid == human_user.principal_uid,
      where: human_user.email == ^email,
      select: %{principal: principal, human_user: human_user, credential: credential}
  end
end
