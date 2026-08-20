defmodule Ankole.Principals.MappingRequests do
  @moduledoc """
  Pending manual identity mappings for signal senders that resolve to no
  Principal.

  Ingress records one row per `(provider, external_id)` when a binding holds an
  unmapped sender for manual review. The operator console lists the rows and
  binds each one to a Principal; the bind writes the platform-subject identity
  and removes the row, so the next message from that sender resolves normally.
  """

  import Ecto.Query, warn: false

  alias Ankole.Principals
  alias Ankole.Principals.MappingRequest
  alias Ankole.Repo

  @doc """
  Records one observation of an unmapped sender.

  Repeated observations converge on one row per `(provider, external_id)` and
  refresh the display and contact hints without erasing values a later, less
  hydrated observation does not carry.
  """
  @spec record_observation(map()) :: {:ok, MappingRequest.t()} | {:error, term()}
  def record_observation(attrs) when is_map(attrs) do
    changeset = MappingRequest.changeset(%MappingRequest{}, attrs)

    with {:ok, incoming} <- Ecto.Changeset.apply_action(changeset, :validate) do
      merged =
        case Repo.get_by(MappingRequest,
               provider: incoming.provider,
               external_id: incoming.external_id
             ) do
          %MappingRequest{} = existing -> merge_observation(existing, incoming)
          nil -> incoming_attrs(incoming)
        end

      %MappingRequest{}
      |> MappingRequest.changeset(merged)
      |> Repo.insert(
        conflict_target: [:provider, :external_id],
        on_conflict: {:replace, [:display_name, :email, :mobile, :metadata, :updated_at]},
        returning: true
      )
    end
  end

  @doc """
  Lists pending mapping requests, most recently observed first.
  """
  @spec list_requests() :: [MappingRequest.t()]
  def list_requests do
    MappingRequest
    |> order_by([request], desc: request.updated_at)
    |> Repo.all()
  end

  @doc """
  Fetches one pending mapping request.
  """
  @spec get_request(String.t()) :: {:ok, MappingRequest.t()} | {:error, :not_found}
  def get_request(id) when is_binary(id) do
    case Repo.get(MappingRequest, id) do
      %MappingRequest{} = request -> {:ok, request}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Binds one pending request to a Principal and removes the request.

  The bind is the operator's explicit decision, so it writes the identity to
  exactly the chosen Principal instead of running the automatic match ladder.
  """
  @spec bind_request(String.t(), String.t()) ::
          {:ok, %{request: MappingRequest.t(), identity: struct()}} | {:error, term()}
  def bind_request(id, principal_uid) when is_binary(id) and is_binary(principal_uid) do
    Repo.transact(fn repo ->
      with {:ok, request} <- get_request(id),
           {:ok, identity} <-
             bind_subject_in_repo(repo, principal_uid, %{
               provider: request.provider,
               external_id: request.external_id,
               metadata: bound_metadata(request)
             }),
           {_count, nil} <-
             repo.delete_all(from r in MappingRequest, where: r.id == ^request.id) do
        {:ok, %{request: request, identity: identity}}
      end
    end)
  end

  @doc """
  Binds a provider subject to a Principal without a pending request.

  This is the proactive console path: an operator maps a known platform
  account, for example a local-login user's IM identity, before that person
  ever messages an Agent. Any pending request for the same subject is removed.
  """
  @spec bind_subject(String.t(), map()) :: {:ok, struct()} | {:error, term()}
  def bind_subject(principal_uid, attrs) when is_binary(principal_uid) and is_map(attrs) do
    Repo.transact(fn repo ->
      with {:ok, identity} <- bind_subject_in_repo(repo, principal_uid, attrs) do
        repo.delete_all(
          from r in MappingRequest,
            where: r.provider == ^identity.provider and r.external_id == ^identity.external_id
        )

        {:ok, identity}
      end
    end)
  end

  @doc """
  Removes one pending request without binding it.

  The sender stays unmapped, so their next message recreates the row.
  """
  @spec delete_request(String.t()) :: {:ok, MappingRequest.t()} | {:error, :not_found}
  def delete_request(id) when is_binary(id) do
    with {:ok, request} <- get_request(id),
         {:ok, deleted} <- Repo.delete(request) do
      {:ok, deleted}
    end
  end

  defp bind_subject_in_repo(repo, principal_uid, attrs) do
    with {:ok, principal_uid} <- Principals.normalize_uid(principal_uid),
         {:ok, principal} <- fetch_human_principal(repo, principal_uid) do
      changeset =
        Ankole.Principals.ExternalIdentity.changeset(%Ankole.Principals.ExternalIdentity{}, %{
          principal_uid: principal.uid,
          provider: Map.get(attrs, :provider),
          external_id: Map.get(attrs, :external_id),
          metadata: Map.get(attrs, :metadata, %{}) |> Map.put("origin", "manual")
        })

      repo.insert(changeset,
        conflict_target: [:provider, :external_id],
        on_conflict: {:replace, [:principal_uid, :metadata, :updated_at]},
        returning: true
      )
    end
  end

  defp fetch_human_principal(repo, principal_uid) do
    case repo.get(Ankole.Principals.Principal, principal_uid) do
      %Ankole.Principals.Principal{type: :human, status: :active} = principal -> {:ok, principal}
      %Ankole.Principals.Principal{type: :human} -> {:error, :principal_disabled}
      %Ankole.Principals.Principal{} -> {:error, :not_human}
      nil -> {:error, :principal_not_found}
    end
  end

  defp bound_metadata(%MappingRequest{} = request) do
    (request.metadata || %{})
    |> Map.take(["alternate_external_ids", "author_metadata"])
    |> Map.merge(%{
      "display_name" => request.display_name,
      "email" => request.email,
      "mobile" => request.mobile
    })
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp merge_observation(%MappingRequest{} = existing, %MappingRequest{} = incoming) do
    %{
      provider: existing.provider,
      external_id: existing.external_id,
      display_name: incoming.display_name || existing.display_name,
      email: incoming.email || existing.email,
      mobile: incoming.mobile || existing.mobile,
      metadata: Map.merge(existing.metadata || %{}, incoming.metadata || %{})
    }
  end

  defp incoming_attrs(%MappingRequest{} = incoming) do
    %{
      provider: incoming.provider,
      external_id: incoming.external_id,
      display_name: incoming.display_name,
      email: incoming.email,
      mobile: incoming.mobile,
      metadata: incoming.metadata || %{}
    }
  end
end
