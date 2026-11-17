defmodule Ankole.AIGateway.ContinuationScope do
  @moduledoc """
  Shared scope resolution and wire helpers for upstream session reuse and
  incremental continuation state.
  """

  alias Ankole.AIGateway.RequestContext
  alias Ankole.Attrs

  @type scope_key ::
          {:socket, String.t()}
          | {:conversation, String.t()}
          | {:session, String.t()}
          | :anonymous

  @doc """
  Resolves the tenant, subject, and session scope of a prepared provider call.
  """
  @spec resolve(map(), map()) ::
          {:ok, %{tenant_id: term(), subject_uid: String.t(), scope_key: scope_key()}}
          | :unavailable
  def resolve(runtime, request) when is_map(runtime) and is_map(request) do
    tenant_id = Ankole.Repo.tenant_id()
    subject_uid = Attrs.optional_text(Map.get(runtime, "subject_uid"))

    if not is_nil(tenant_id) and is_binary(subject_uid) do
      request_context = Map.get(runtime, "request_context") || %{}

      {:ok,
       %{
         tenant_id: tenant_id,
         subject_uid: subject_uid,
         scope_key: scope_key(request_context, request)
       }}
    else
      :unavailable
    end
  end

  def resolve(_runtime, _request), do: :unavailable

  @doc "Returns true when `scope_key` names a dedicated conversation or socket."
  @spec explicit_session?(scope_key()) :: boolean()
  def explicit_session?(:anonymous), do: false
  def explicit_session?(_scope_key), do: true

  @doc "Extracts the provider row identity and last-modified marker for capability caches."
  @spec provider_version_key(map()) :: {String.t(), term()} | nil
  def provider_version_key(runtime) when is_map(runtime) do
    case Map.get(runtime, "provider") do
      %{id: id} = provider when is_binary(id) and id != "" ->
        {id, Map.get(provider, :updated_at)}

      _other ->
        case Attrs.optional_text(Map.get(runtime, "provider_id")) do
          nil -> nil
          provider_id -> {provider_id, nil}
        end
    end
  end

  @doc "Returns the provider row ID used for pool partitioning."
  @spec provider_row_id(map()) :: String.t() | nil
  def provider_row_id(runtime) when is_map(runtime) do
    case Map.get(runtime, "provider") do
      %{id: id} when is_binary(id) and id != "" -> id
      _other -> Attrs.optional_text(Map.get(runtime, "provider_id"))
    end
  end

  @doc "Parses the lowercase hostname from a prepared spec's upstream URL."
  @spec upstream_host(map()) :: String.t() | nil
  def upstream_host(spec) when is_map(spec) do
    url =
      get_in(spec, [:upstream, :url]) ||
        get_in(spec, ["upstream", "url"])

    case url do
      value when is_binary(value) and value != "" ->
        case URI.parse(value).host do
          host when is_binary(host) and host != "" -> String.downcase(host)
          _other -> nil
        end

      _other ->
        nil
    end
  end

  @doc "Returns the UTF-8 JSON byte length of `value`, or `nil` when encoding fails."
  @spec encoded_bytes(term()) :: non_neg_integer() | nil
  def encoded_bytes(value) do
    case Ankole.JSON.encode(value) do
      {:ok, encoded} -> byte_size(encoded)
      {:error, _reason} -> nil
    end
  end

  defp scope_key(request_context, request) do
    socket_id = Attrs.optional_text(Map.get(request_context, "socket_session_id"))
    conversation_id = Attrs.optional_text(Map.get(request_context, "conversation_id"))
    session_key = RequestContext.session_key(request_context, request)

    cond do
      is_binary(socket_id) -> {:socket, socket_id}
      is_binary(conversation_id) -> {:conversation, conversation_id}
      is_binary(session_key) -> {:session, session_key}
      true -> :anonymous
    end
  end
end
