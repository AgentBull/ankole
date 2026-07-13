defmodule Ankole.Brain.Scope do
  @moduledoc """
  Brain library routing derived only from the declaration on an AIGateway
  conversation.

  The declaration lives at `conversation.metadata["brain"]`. No channel event,
  provider metadata, or ambient runtime state is consulted as a fallback.
  """

  alias Ankole.AIGateway.Schemas.Conversation
  alias Ankole.Principals

  @enforce_keys [:owner_uid, :readable_store_keys, :writable_store_key, :current_channel]
  defstruct [:owner_uid, :readable_store_keys, :writable_store_key, :current_channel]

  @type current_channel :: %{id: String.t(), kind: String.t()}
  @type t :: %__MODULE__{
          owner_uid: String.t(),
          readable_store_keys: [String.t()] | :all,
          writable_store_key: String.t() | nil,
          current_channel: current_channel() | nil
        }

  @type error_reason ::
          :missing_brain_scope
          | :invalid_brain_scope
          | :invalid_owner_uid
          | :invalid_peer_uid

  @doc "Parses a Brain scope from an AIGateway conversation's declared metadata."
  @spec from_conversation(Conversation.t() | map()) :: {:ok, t()} | {:error, error_reason()}
  def from_conversation(%{subject_uid: owner_uid, metadata: metadata}) do
    from_metadata(owner_uid, metadata)
  end

  def from_conversation(_conversation), do: {:error, :invalid_brain_scope}

  @doc "Parses the exact `metadata[\"brain\"]` declaration for an owner."
  @spec from_metadata(term(), term()) :: {:ok, t()} | {:error, error_reason()}
  def from_metadata(owner_uid, metadata) when is_map(metadata) do
    with {:ok, owner_uid} <- normalize_owner(owner_uid),
         {:ok, declaration} <- fetch_declaration(metadata) do
      parse_visibility(owner_uid, declaration)
    end
  end

  def from_metadata(_owner_uid, _metadata), do: {:error, :missing_brain_scope}

  @doc "Builds an explicit console scope after the web authorization boundary."
  @spec for_console(term(), :all | String.t()) :: {:ok, t()} | {:error, error_reason()}
  def for_console(owner_uid, :all) do
    with {:ok, owner_uid} <- normalize_owner(owner_uid),
         {:ok, readable, writable} <- normalize_console_store(:all) do
      {:ok,
       %__MODULE__{
         owner_uid: owner_uid,
         readable_store_keys: readable,
         writable_store_key: writable,
         current_channel: nil
       }}
    end
  end

  def for_console(owner_uid, store_key), do: for_store(owner_uid, store_key)

  @doc "Restricts a read capability to one store it already permits."
  @spec restrict_read_store(t(), String.t()) :: {:ok, t()} | {:error, :brain_store_not_readable}
  def restrict_read_store(%__MODULE__{readable_store_keys: :all} = scope, store_key)
      when is_binary(store_key) do
    {:ok, %{scope | readable_store_keys: [store_key]}}
  end

  def restrict_read_store(%__MODULE__{readable_store_keys: stores} = scope, store_key)
      when is_list(stores) and is_binary(store_key) do
    if store_key in stores,
      do: {:ok, %{scope | readable_store_keys: [store_key]}},
      else: {:error, :brain_store_not_readable}
  end

  @doc "Builds one explicit library scope for trusted server-side jobs or console writes."
  @spec for_store(term(), String.t()) :: {:ok, t()} | {:error, error_reason()}
  def for_store(owner_uid, store_key) do
    with {:ok, owner_uid} <- normalize_owner(owner_uid),
         {:ok, readable, writable} <- normalize_console_store(store_key),
         true <- is_binary(writable) do
      {:ok,
       %__MODULE__{
         owner_uid: owner_uid,
         readable_store_keys: readable,
         writable_store_key: writable,
         current_channel: nil
       }}
    else
      false -> {:error, :invalid_brain_scope}
      {:error, _reason} = error -> error
    end
  end

  defp fetch_declaration(metadata) do
    case Map.get(metadata, "brain") do
      nil -> {:error, :missing_brain_scope}
      declaration when is_map(declaration) -> {:ok, declaration}
      _invalid -> {:error, :invalid_brain_scope}
    end
  end

  defp parse_channel(%{"channel_id" => channel_id, "channel_kind" => channel_kind})
       when is_binary(channel_id) and is_binary(channel_kind) do
    channel_id = String.trim(channel_id)
    channel_kind = String.trim(channel_kind)

    if channel_id == "" or channel_kind == "" do
      {:error, :invalid_brain_scope}
    else
      {:ok, %{id: channel_id, kind: channel_kind}}
    end
  end

  defp parse_channel(_declaration), do: {:error, :invalid_brain_scope}

  defp parse_visibility(owner_uid, %{"visibility" => "public"} = declaration) do
    with {:ok, channel} <- parse_optional_channel(declaration) do
      {:ok,
       %__MODULE__{
         owner_uid: owner_uid,
         readable_store_keys: ["public"],
         writable_store_key: "public",
         current_channel: channel
       }}
    end
  end

  defp parse_visibility(owner_uid, %{"visibility" => "dm", "peer_uid" => peer_uid} = declaration) do
    with {:ok, channel} <- parse_channel(declaration) do
      case Principals.normalize_uid(peer_uid) do
        {:ok, peer_uid} ->
          store_key = "dm:#{peer_uid}"

          {:ok,
           %__MODULE__{
             owner_uid: owner_uid,
             readable_store_keys: [store_key, "public"],
             writable_store_key: store_key,
             current_channel: channel
           }}

        {:error, :invalid_uid} ->
          {:error, :invalid_peer_uid}
      end
    end
  end

  defp parse_visibility(_owner_uid, _declaration),
    do: {:error, :invalid_brain_scope}

  defp parse_optional_channel(declaration) do
    case {Map.has_key?(declaration, "channel_id"), Map.has_key?(declaration, "channel_kind")} do
      {false, false} -> {:ok, nil}
      {true, true} -> parse_channel(declaration)
      _partial -> {:error, :invalid_brain_scope}
    end
  end

  defp normalize_owner(owner_uid) do
    case Principals.normalize_uid(owner_uid) do
      {:ok, owner_uid} -> {:ok, owner_uid}
      {:error, :invalid_uid} -> {:error, :invalid_owner_uid}
    end
  end

  defp normalize_console_store(:all), do: {:ok, :all, nil}
  defp normalize_console_store("public"), do: {:ok, ["public"], "public"}

  defp normalize_console_store("dm:" <> peer_uid) do
    case Principals.normalize_uid(peer_uid) do
      {:ok, peer_uid} ->
        store_key = "dm:#{peer_uid}"
        {:ok, [store_key, "public"], store_key}

      {:error, :invalid_uid} ->
        {:error, :invalid_brain_scope}
    end
  end

  defp normalize_console_store(_store_key), do: {:error, :invalid_brain_scope}
end
