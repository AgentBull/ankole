defmodule Ankole.Principals.MappingRequests do
  @moduledoc """
  Pending manual identity mappings for signal senders that resolve to no
  Principal.

  Observe records one row per `(provider, external_id)` when a binding holds an
  unmapped sender for manual review. The operator console lists the rows and
  binds each one to a Principal; the bind writes the platform-subject identity
  and removes the row, so the next message from that sender resolves normally.
  """

  require Ash.Query

  alias Ankole.Principals
  alias Ankole.Principals.ExternalIdentity
  alias Ankole.Principals.MappingRequest
  alias Ankole.Principals.Principal

  @doc """
  Records one observation of an unmapped sender.

  Repeated observations converge on one row per `(provider, external_id)` and
  refresh the display and contact hints without erasing values a later, less
  hydrated observation does not carry.
  """
  @spec record_observation(map()) ::
          {:ok, MappingRequest.t() | :already_mapped} | {:error, term()}
  def record_observation(attrs) when is_map(attrs),
    do: Ankole.Ash.run_action(MappingRequest, :record_observation, %{attrs: attrs})

  @doc false
  def record_observation_in_tx(repo, attrs) do
    with changeset <- Ankole.Ash.for_create(MappingRequest, :observe_in_tx, attrs),
         {:ok, incoming} <- Ash.Changeset.apply_attributes(changeset) do
      record_observation_in_repo(repo, incoming)
    end
  end

  @doc """
  Lists pending mapping requests, most recently observed first.
  """
  @spec list_requests() :: [MappingRequest.t()]
  def list_requests do
    MappingRequest
    |> Ash.Query.for_read(:console_list)
    |> Ankole.Ash.read!()
  end

  # Fetches one pending mapping request.
  #
  @spec get_request(String.t()) :: {:ok, MappingRequest.t()} | {:error, :not_found}
  defp get_request(id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, %MappingRequest{} = request} <- Principals.get_mapping_request(id) do
      {:ok, request}
    else
      _not_found -> {:error, :not_found}
    end
  end

  @doc """
  Binds one pending request to a Principal and removes the request.

  The bind is the operator's explicit decision, so it writes the identity to
  exactly the chosen Principal instead of running the automatic match ladder.
  """
  @spec bind_request(String.t(), String.t()) :: {:ok, ExternalIdentity.t()} | {:error, term()}
  def bind_request(id, principal_uid) when is_binary(id) and is_binary(principal_uid) do
    Ankole.Ash.run_action(MappingRequest, :bind_request, %{id: id, principal_uid: principal_uid})
    |> Ankole.Errors.reason()
  end

  @doc false
  def bind_request_in_tx(repo, id, principal_uid) do
    with {:ok, known_request} <- get_request(id),
         :ok <-
           Principals.lock_platform_subject(
             repo,
             known_request.provider,
             known_request.external_id
           ),
         {:ok, request} <- get_request(id),
         {:ok, identity} <-
           bind_subject_in_repo(repo, principal_uid, %{
             provider: request.provider,
             external_id: request.external_id,
             metadata: bound_metadata(request)
           }),
         :ok <-
           Principals.delete_pending_mapping_request(
             repo,
             request.provider,
             request.external_id
           ) do
      {:ok, identity}
    end
  end

  @doc """
  Binds a provider subject to a Principal without a pending request.

  This is the proactive console path: an operator maps a known platform
  account, for example a local-login user's IM identity, before that person
  ever messages an Agent. Any pending request for the same subject is removed.
  """
  @spec bind_subject(String.t(), map()) :: {:ok, struct()} | {:error, term()}
  def bind_subject(principal_uid, %{provider: provider, external_id: external_id})
      when is_binary(principal_uid) and is_binary(provider) and is_binary(external_id) do
    Ankole.Ash.run_action(MappingRequest, :bind_subject, %{
      principal_uid: principal_uid,
      provider: provider,
      external_id: external_id
    })
    |> Ankole.Errors.reason()
  end

  @doc false
  def bind_subject_in_tx(repo, principal_uid, attrs) do
    with :ok <- Principals.lock_platform_subject(repo, attrs.provider, attrs.external_id),
         {:ok, identity} <- bind_subject_in_repo(repo, principal_uid, attrs),
         :ok <-
           Principals.delete_pending_mapping_request(
             repo,
             identity.provider,
             identity.external_id
           ) do
      {:ok, identity}
    end
  end

  @doc """
  Removes one pending request without binding it.

  The sender stays unmapped, so their next message recreates the row.
  """
  @spec delete_request(String.t()) :: {:ok, MappingRequest.t()} | {:error, :not_found}
  def delete_request(id) when is_binary(id) do
    with {:ok, id} <- cast_request_id(id),
         {:ok, [request]} <-
           MappingRequest
           |> Ash.Query.filter(id == ^id)
           |> Ankole.Ash.destroy_where(:delete_in_tx) do
      {:ok, request}
    else
      {:ok, []} -> {:error, :not_found}
      error -> error
    end
  end

  defp cast_request_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end

  defp record_observation_in_repo(repo, incoming) do
    with :ok <- Principals.lock_platform_subject(repo, incoming.provider, incoming.external_id) do
      case ExternalIdentity
           |> Ash.Query.filter(
             provider == ^incoming.provider and external_id == ^incoming.external_id
           )
           |> Ankole.Ash.read_one!() do
        %ExternalIdentity{} ->
          :ok =
            Principals.delete_pending_mapping_request(
              repo,
              incoming.provider,
              incoming.external_id
            )

          {:ok, :already_mapped}

        nil ->
          merged =
            case MappingRequest
                 |> Ash.Query.filter(
                   provider == ^incoming.provider and external_id == ^incoming.external_id
                 )
                 |> Ankole.Ash.read_one!() do
              %MappingRequest{} = existing -> merge_observation(existing, incoming)
              nil -> incoming_attrs(incoming)
            end

          Ankole.Ash.create(MappingRequest, :observe_in_tx, merged)
      end
    end
  end

  defp bind_subject_in_repo(repo, principal_uid, attrs) do
    with {:ok, principal_uid} <- Principals.normalize_uid(principal_uid),
         {:ok, principal} <- fetch_human_principal(principal_uid) do
      Principals.bind_external_identity(repo, %{
        principal_uid: principal.uid,
        provider: Map.get(attrs, :provider),
        external_id: Map.get(attrs, :external_id),
        metadata: Map.get(attrs, :metadata, %{}) |> Map.put("origin", "manual")
      })
    end
  end

  defp fetch_human_principal(principal_uid) do
    case Principals.get_principal(principal_uid) do
      {:ok, %Principal{type: :human, status: :active} = principal} -> {:ok, principal}
      {:ok, %Principal{type: :human}} -> {:error, :principal_disabled}
      {:ok, %Principal{}} -> {:error, :not_human}
      {:error, :not_found} -> {:error, :principal_not_found}
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
