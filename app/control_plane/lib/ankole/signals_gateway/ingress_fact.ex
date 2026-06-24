defmodule Ankole.SignalsGateway.IngressFact do
  @moduledoc """
  Internal constructed ingress fact used after adapter input normalization.

  Adapter-facing APIs accept concrete maps, but the gateway pipeline should not
  pass those maps through as durable intent. Each accepted ingress shape becomes
  this struct before routing, mirroring, or actor input planning.
  """

  alias Ankole.SignalsGateway.JsonPayload

  @enforce_keys [:kind, :agent_uid, :binding_name, :adapter, :ingress_event_id]
  defstruct [
    :kind,
    :agent_uid,
    :binding_name,
    :adapter,
    :ingress_event_id,
    :signal_channel_id,
    :provider_entry_id,
    :provider_thread_id,
    :channel_kind,
    :reply_mode,
    :channel_name,
    :channel_title,
    :channel_visibility,
    :channel_metadata,
    :channel_raw_payload,
    :text,
    :formatted_content,
    :attachments,
    :links,
    :author,
    :mentions,
    :metadata,
    :raw_payload,
    :provider_time,
    :explicit?,
    :mirror_only?,
    :actor_input_type,
    :command_prefixes,
    :sender_key,
    :gateway_time,
    :lifecycle_kind,
    :reaction_key,
    :actor_key,
    :action,
    :raw_reaction_key,
    :action_id,
    :session_id,
    :timer_id,
    :internal_subject,
    :internal,
    :command_payload
  ]

  @type t :: %__MODULE__{}

  @doc """
  Constructs a provider entry receive fact.
  """
  @spec entry(map()) :: {:ok, t()} | {:error, term()}
  def entry(attrs), do: new(:entry_received, attrs)

  @doc """
  Constructs a provider entry lifecycle fact.
  """
  @spec lifecycle(map()) :: {:ok, t()} | {:error, term()}
  def lifecycle(attrs), do: new(:entry_lifecycle, attrs)

  @doc """
  Constructs a provider reaction fact.
  """
  @spec reaction(map()) :: {:ok, t()} | {:error, term()}
  def reaction(attrs), do: new(:reaction, attrs)

  @doc """
  Constructs a provider action fact.
  """
  @spec action(map()) :: {:ok, t()} | {:error, term()}
  def action(attrs), do: new(:action, attrs)

  @doc """
  Constructs an internal source fact such as a timer fire.
  """
  @spec internal(map()) :: {:ok, t()} | {:error, term()}
  def internal(attrs), do: new(:internal, attrs)

  defp new(kind, attrs) when is_map(attrs) do
    with {:ok, normalized_attrs} <- normalize_durable_fields(kind, attrs),
         {:ok, fact} <- build(kind, normalized_attrs) do
      {:ok, fact}
    end
  end

  defp new(_kind, _attrs), do: {:error, :invalid_ingress_fact_attrs}

  defp build(kind, attrs) do
    attrs =
      attrs
      |> Map.put(:kind, kind)
      |> Map.update(:agent_uid, nil, &normalize_uid/1)

    {:ok, struct!(__MODULE__, attrs)}
  rescue
    KeyError -> {:error, :invalid_ingress_fact_attrs}
  end

  defp normalize_durable_fields(kind, attrs) do
    attrs
    |> normalize_map_field(:channel_metadata)
    |> normalize_map_field(:channel_raw_payload)
    |> normalize_map_field(:formatted_content)
    |> normalize_list_field(:attachments)
    |> normalize_list_field(:links)
    |> normalize_map_field(:author)
    |> normalize_list_field(:mentions)
    |> normalize_map_field(:metadata)
    |> normalize_map_field(:raw_payload)
    |> normalize_action_payload(kind)
    |> normalize_map_field(:internal)
    |> normalize_map_field(:command_payload)
  end

  defp normalize_action_payload({:error, _reason} = error, _kind), do: error
  defp normalize_action_payload({:ok, attrs}, kind), do: normalize_action_payload(attrs, kind)
  defp normalize_action_payload(attrs, :action), do: normalize_map_field(attrs, :action)
  defp normalize_action_payload(attrs, _kind), do: {:ok, attrs}

  defp normalize_map_field({:error, _reason} = error, _field), do: error

  defp normalize_map_field({:ok, attrs}, field), do: normalize_map_field(attrs, field)

  defp normalize_map_field(attrs, field) do
    case Map.fetch(attrs, field) do
      {:ok, nil} ->
        {:ok, attrs}

      {:ok, value} ->
        case JsonPayload.normalize_map(value, allow_datetime: true) do
          {:ok, normalized} -> {:ok, Map.put(attrs, field, normalized)}
          {:error, reason} -> {:error, {:invalid_json_payload, field, reason}}
        end

      :error ->
        {:ok, attrs}
    end
  end

  defp normalize_list_field({:error, _reason} = error, _field), do: error

  defp normalize_list_field({:ok, attrs}, field), do: normalize_list_field(attrs, field)

  defp normalize_list_field(attrs, field) do
    case Map.fetch(attrs, field) do
      {:ok, nil} ->
        {:ok, attrs}

      {:ok, value} ->
        case JsonPayload.normalize_list(value, allow_datetime: true) do
          {:ok, normalized} -> {:ok, Map.put(attrs, field, normalized)}
          {:error, reason} -> {:error, {:invalid_json_payload, field, reason}}
        end

      :error ->
        {:ok, attrs}
    end
  end

  defp normalize_uid(uid) when is_binary(uid), do: uid |> String.trim() |> String.downcase()
  defp normalize_uid(uid), do: uid
end
