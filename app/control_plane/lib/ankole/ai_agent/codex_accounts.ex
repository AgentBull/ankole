defmodule Ankole.AIAgent.CodexAccounts do
  @moduledoc """
  Durable ChatGPT subscription accounts for the Codex worker runtime.
  """

  import Ecto.Query, warn: false

  alias Ankole.AIAgent.CodexAccounts.Account
  alias Ankole.AIAgent.CodexAccounts.Crypto
  alias Ankole.Kernel, as: NativeKernel
  alias Ankole.Principals.Agent
  alias Ankole.Repo
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorSessionWorkerAssignment
  alias Ankole.SubagentDelegations.Schemas.Delegation
  alias Ankole.WorkerFiles

  @nonterminal_statuses ~w(queued running waiting_on_user)

  @spec list_accounts() :: [map()]
  def list_accounts do
    Account
    |> order_by([account], asc: fragment("lower(?)", account.name))
    |> Repo.all()
    |> Enum.map(&projection/1)
  end

  @spec fetch_account(String.t()) :: {:ok, Account.t()} | {:error, :not_found}
  def fetch_account(account_id) when is_binary(account_id) do
    case Repo.get(Account, account_id) do
      %Account{} = account -> {:ok, account}
      nil -> {:error, :not_found}
    end
  end

  def fetch_account(_account_id), do: {:error, :not_found}

  @spec get_account(String.t()) :: {:ok, map()} | {:error, term()}
  def get_account(account_id) do
    with {:ok, account} <- fetch_account(account_id), do: {:ok, projection(account)}
  end

  @spec create_account(map()) :: {:ok, Account.t()} | {:error, term()}
  def create_account(attrs) when is_map(attrs) do
    Repo.transact(fn repo ->
      with {:ok, normalized} <- normalize_write(attrs, nil),
           {:ok, encrypted} <- Crypto.seal(normalized.auth_json, normalized.account_id) do
        %Account{}
        |> Account.changeset(%{
          account_id: normalized.account_id,
          name: normalized.name,
          encrypted_auth_json: encrypted,
          auth_hash: normalized.auth_hash
        })
        |> repo.insert()
      end
    end)
  end

  @spec update_account(String.t(), map()) :: {:ok, Account.t()} | {:error, term()}
  def update_account(account_id, attrs) when is_binary(account_id) and is_map(attrs) do
    Repo.transact(fn repo ->
      with %Account{} = account <- lock_account(repo, account_id),
           {:ok, normalized} <- normalize_write(attrs, account),
           {:ok, changes} <- update_changes(account, normalized) do
        account
        |> Account.changeset(changes)
        |> repo.update()
      else
        nil -> {:error, :not_found}
        {:error, _reason} = error -> error
      end
    end)
  end

  @spec resolve_auth(String.t()) :: {:ok, map()} | {:error, term()}
  def resolve_auth(account_id) do
    with {:ok, %Account{} = account} <- fetch_account(account_id),
         {:ok, auth_json} <- Crypto.unseal(account.encrypted_auth_json, account.account_id) do
      {:ok, %{account_id: account.account_id, auth_json: auth_json, auth_hash: account.auth_hash}}
    end
  end

  @spec update_auth(String.t(), String.t()) :: {:ok, Account.t()} | {:error, term()}
  def update_auth(account_id, auth_json)
      when is_binary(account_id) and is_binary(auth_json) do
    Repo.transact(fn repo ->
      with %Account{} = account <- lock_account(repo, account_id),
           {:ok, parsed_account_id} <- account_id_from_auth(auth_json),
           :ok <- ensure_account_id(parsed_account_id, account.account_id),
           {:ok, encrypted} <- Crypto.seal(auth_json, account.account_id) do
        account
        |> Account.changeset(%{
          encrypted_auth_json: encrypted,
          auth_hash: NativeKernel.generic_hash(auth_json)
        })
        |> repo.update()
      else
        nil -> {:error, :not_found}
        {:error, _reason} = error -> error
      end
    end)
  end

  @spec delete_account(String.t()) :: {:ok, Account.t()} | {:error, term()}
  def delete_account(account_id) when is_binary(account_id) do
    with :ok <- ensure_deletable(account_id),
         :ok <- delete_account_home(account_id) do
      Repo.transact(fn repo ->
        with %Account{} = account <- lock_account(repo, account_id),
             [] <- model_profile_references(repo, account_id),
             [] <- delegation_references(repo, account_id) do
          repo.delete(account)
        else
          nil -> {:error, :not_found}
          references when is_list(references) -> {:error, {:codex_account_in_use, references}}
        end
      end)
    end
  end

  defp delete_account_home(account_id) do
    case WorkerFiles.delete("codex_accounts", account_id, recursive: true) do
      {:ok, _result} ->
        :ok

      {:error,
       %{
         "code" => "operation_failed",
         "message" => "path does not exist: /codex_accounts/" <> ^account_id
       }} ->
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  @spec projection(Account.t()) :: map()
  def projection(%Account{} = account) do
    %{
      "account_id" => account.account_id,
      "name" => account.name,
      "auth_hash" => account.auth_hash,
      "inserted_at" => DateTime.to_iso8601(account.inserted_at),
      "updated_at" => DateTime.to_iso8601(account.updated_at)
    }
  end

  defp normalize_write(attrs, account) do
    attrs = normalize_keys(attrs)
    name = Map.get(attrs, "name", account && account.name)
    auth_json = Map.get(attrs, "auth_json")

    cond do
      not is_binary(name) or String.trim(name) == "" ->
        {:error, {:missing, "name"}}

      is_nil(account) and not is_binary(auth_json) ->
        {:error, {:missing, "auth_json"}}

      is_binary(auth_json) ->
        with {:ok, account_id} <- account_id_from_auth(auth_json),
             :ok <- ensure_account_id(account_id, account && account.account_id) do
          {:ok,
           %{
             name: String.trim(name),
             account_id: account_id,
             auth_json: auth_json,
             auth_hash: NativeKernel.generic_hash(auth_json)
           }}
        end

      true ->
        {:ok,
         %{
           name: String.trim(name),
           account_id: account.account_id,
           auth_json: nil,
           auth_hash: account.auth_hash
         }}
    end
  end

  defp update_changes(account, %{auth_json: nil} = normalized) do
    {:ok, %{name: normalized.name, auth_hash: account.auth_hash}}
  end

  defp update_changes(account, normalized) do
    with {:ok, encrypted} <- Crypto.seal(normalized.auth_json, account.account_id) do
      {:ok,
       %{
         name: normalized.name,
         encrypted_auth_json: encrypted,
         auth_hash: normalized.auth_hash
       }}
    end
  end

  defp account_id_from_auth(auth_json) do
    with {:ok, auth} <- Ankole.JSON.decode(auth_json),
         %{"tokens" => %{"account_id" => account_id}} when is_binary(account_id) <- auth,
         account_id <- String.trim(account_id),
         true <- account_id != "" do
      {:ok, account_id}
    else
      {:error, reason} -> {:error, {:invalid_auth_json, reason}}
      _value -> {:error, :codex_account_id_missing}
    end
  end

  defp ensure_account_id(account_id, nil), do: validate_account_id(account_id)
  defp ensure_account_id(account_id, account_id), do: validate_account_id(account_id)
  defp ensure_account_id(_account_id, _expected), do: {:error, :codex_account_id_mismatch}

  defp validate_account_id("aigateway"), do: {:error, :reserved_codex_account_id}

  defp validate_account_id(account_id) do
    case Regex.match?(~r/\A(?!\.{1,2}\z)[A-Za-z0-9._-]+\z/, account_id) do
      true -> :ok
      false -> {:error, :invalid_codex_account_id}
    end
  end

  defp lock_account(repo, account_id) do
    Account
    |> where([account], account.account_id == ^account_id)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp ensure_deletable(account_id) do
    with {:ok, _account} <- fetch_account(account_id),
         [] <- model_profile_references(Repo, account_id),
         [] <- delegation_references(Repo, account_id) do
      :ok
    else
      references when is_list(references) -> {:error, {:codex_account_in_use, references}}
      {:error, _reason} = error -> error
    end
  end

  defp model_profile_references(repo, account_id) do
    Agent
    |> where(
      [agent],
      fragment(
        "coalesce(? #>> '{ai_agent,models,coding,codex_account_id}', '') = ?",
        agent.options,
        ^account_id
      )
    )
    |> select([agent], %{type: "model_profile", agent_uid: agent.uid})
    |> repo.all()
  end

  defp delegation_references(repo, account_id) do
    Delegation
    |> join(
      :left,
      [delegation],
      assignment in ActorSessionWorkerAssignment,
      on:
        assignment.agent_uid == delegation.agent_uid and
          assignment.session_id == fragment("'subagent:' || ?", delegation.id) and
          assignment.status in ["assigned", "draining"]
    )
    |> where(
      [delegation, assignment],
      delegation.codex_account_id == ^account_id and
        (delegation.status in ^@nonterminal_statuses or not is_nil(assignment.id))
    )
    |> select([delegation, _assignment], %{
      type: "delegation",
      delegation_id: delegation.id
    })
    |> repo.all()
  end

  defp normalize_keys(attrs) do
    Map.new(attrs, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      entry -> entry
    end)
  end
end
