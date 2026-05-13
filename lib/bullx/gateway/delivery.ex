defmodule BullX.Gateway.Delivery do
  @moduledoc """
  External outbound delivery carrier accepted by `BullX.Gateway.deliver/1`.

  A Delivery is already authorized before it reaches Gateway. This module only
  validates the transport carrier: target source, operation, content shape, and
  JSON-neutral replay data.
  """

  alias BullX.Gateway.{JSON, OutboundError}

  @ops [:send, :edit, :stream]

  @enforce_keys [:id, :generation, :op, :adapter, :channel_id, :scope_id, :content]
  defstruct [
    :id,
    :generation,
    :op,
    :adapter,
    :channel_id,
    :scope_id,
    :thread_id,
    :reply_to_external_id,
    :target_external_id,
    :content,
    :caused_by_signal_id,
    extensions: %{}
  ]

  @type op :: :send | :edit | :stream

  @type t :: %__MODULE__{
          id: String.t(),
          generation: non_neg_integer(),
          op: op(),
          adapter: String.t(),
          channel_id: String.t(),
          scope_id: String.t(),
          thread_id: String.t() | nil,
          reply_to_external_id: String.t() | nil,
          target_external_id: String.t() | nil,
          content: term(),
          caused_by_signal_id: String.t() | nil,
          extensions: map()
        }

  @spec normalize(t() | map()) :: {:ok, t()} | {:error, OutboundError.t()}
  def normalize(%__MODULE__{} = delivery), do: validate(delivery)

  def normalize(%{} = attrs) do
    with {:ok, id} <- uuid(map_value(attrs, "id"), :id),
         {:ok, generation} <- generation(map_value(attrs, "generation")),
         {:ok, op} <- op(map_value(attrs, "op")),
         {:ok, adapter, channel_id} <- channel(attrs),
         {:ok, scope_id} <- required_string(map_value(attrs, "scope_id"), :scope_id),
         {:ok, thread_id} <- optional_string(map_value(attrs, "thread_id"), :thread_id),
         {:ok, reply_to_external_id} <-
           optional_string(map_value(attrs, "reply_to_external_id"), :reply_to_external_id),
         {:ok, target_external_id} <-
           optional_string(map_value(attrs, "target_external_id"), :target_external_id),
         {:ok, caused_by_signal_id} <-
           optional_uuid(map_value(attrs, "caused_by_signal_id"), :caused_by_signal_id),
         {:ok, extensions} <- json_object(map_value(attrs, "extensions") || %{}, :extensions),
         {:ok, content} <- content(op, map_value(attrs, "content")),
         delivery <-
           %__MODULE__{
             id: id,
             generation: generation,
             op: op,
             adapter: adapter,
             channel_id: channel_id,
             scope_id: scope_id,
             thread_id: thread_id,
             reply_to_external_id: reply_to_external_id,
             target_external_id: target_external_id,
             content: content,
             caused_by_signal_id: caused_by_signal_id,
             extensions: extensions
           } do
      validate(delivery)
    else
      {:error, %OutboundError{} = error} -> {:error, error}
      {:error, reason} -> {:error, malformed(reason)}
      :error -> {:error, malformed(:invalid_delivery)}
    end
  end

  def normalize(_value), do: {:error, malformed(:invalid_delivery)}

  @spec dump(t()) :: map()
  def dump(%__MODULE__{} = delivery) do
    %{
      "id" => delivery.id,
      "generation" => delivery.generation,
      "op" => Atom.to_string(delivery.op),
      "channel" => %{"adapter" => delivery.adapter, "channel_id" => delivery.channel_id},
      "scope_id" => delivery.scope_id,
      "content" => dumped_content(delivery),
      "extensions" => delivery.extensions
    }
    |> maybe_put("thread_id", delivery.thread_id)
    |> maybe_put("reply_to_external_id", delivery.reply_to_external_id)
    |> maybe_put("target_external_id", delivery.target_external_id)
    |> maybe_put("caused_by_signal_id", delivery.caused_by_signal_id)
  end

  @spec replay_snapshot(t()) :: {:ok, map()} | {:error, OutboundError.t()}
  def replay_snapshot(%__MODULE__{op: op} = delivery) when op in [:send, :edit],
    do: {:ok, dump(delivery)}

  def replay_snapshot(%__MODULE__{op: :stream}) do
    {:error, OutboundError.new(:not_replayable, "stream deliveries are not replayable")}
  end

  @spec content_kinds(t()) :: [String.t()]
  def content_kinds(%__MODULE__{op: :stream}), do: []

  def content_kinds(%__MODULE__{content: content}) do
    Enum.map(content, &Map.fetch!(&1, "kind"))
  end

  @spec put_generation(t(), non_neg_integer()) :: t()
  def put_generation(%__MODULE__{} = delivery, generation)
      when is_integer(generation) and generation >= 0 do
    %{delivery | generation: generation}
  end

  @spec channel_key(t()) :: {String.t(), String.t()}
  def channel_key(%__MODULE__{adapter: adapter, channel_id: channel_id}),
    do: {adapter, channel_id}

  defp validate(%__MODULE__{op: :edit, target_external_id: nil}) do
    {:error, malformed(:missing_target_external_id)}
  end

  defp validate(%__MODULE__{} = delivery), do: {:ok, delivery}

  defp dumped_content(%__MODULE__{op: :stream}), do: []
  defp dumped_content(%__MODULE__{content: content}), do: content

  defp content(op, value) when op in [:send, :edit] do
    with [_ | _] = blocks <- value,
         {:ok, blocks} <- JSON.stringify_keys(blocks),
         true <- Enum.all?(blocks, &content_block?/1) do
      {:ok, blocks}
    else
      _other -> {:error, :invalid_content}
    end
  end

  defp content(:stream, value) do
    case Enumerable.impl_for(value) do
      nil -> {:error, :invalid_stream_content}
      _impl -> {:ok, value}
    end
  end

  defp content_block?(%{"kind" => kind} = block) when is_binary(kind) and kind != "" do
    JSON.json_object?(block)
  end

  defp content_block?(_block), do: false

  defp channel(attrs) do
    case map_value(attrs, "channel") do
      {adapter, channel_id} ->
        required_channel(adapter, channel_id)

      [adapter, channel_id] ->
        required_channel(adapter, channel_id)

      %{} = channel ->
        required_channel(map_value(channel, "adapter"), map_value(channel, "channel_id"))

      _other ->
        required_channel(map_value(attrs, "adapter"), map_value(attrs, "channel_id"))
    end
  end

  defp required_channel(adapter, channel_id) do
    with {:ok, adapter} <- required_string(adapter, :adapter),
         {:ok, channel_id} <- required_string(channel_id, :channel_id) do
      {:ok, adapter, channel_id}
    end
  end

  defp op(value) when value in @ops, do: {:ok, value}

  defp op(value) when is_binary(value) do
    case value do
      "send" -> {:ok, :send}
      "edit" -> {:ok, :edit}
      "stream" -> {:ok, :stream}
      _other -> {:error, :invalid_op}
    end
  end

  defp op(_value), do: {:error, :invalid_op}

  defp generation(nil), do: {:ok, 0}
  defp generation(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp generation(_value), do: {:error, :invalid_generation}

  defp uuid(value, _field) when is_binary(value) do
    with {:ok, ^value} <- Ecto.UUID.cast(value),
         :ok <- validate_uuid_v7(value) do
      {:ok, value}
    else
      _other -> {:error, :invalid_uuid}
    end
  end

  defp uuid(_value, field), do: {:error, {:required_uuid, field}}

  defp optional_uuid(nil, _field), do: {:ok, nil}

  defp optional_uuid(value, field) do
    case uuid(value, field) do
      {:ok, value} -> {:ok, value}
      {:error, _reason} -> {:error, {:invalid_uuid, field}}
    end
  end

  defp validate_uuid_v7(value) do
    case String.at(value, 14) do
      "7" -> :ok
      _other -> {:error, :not_uuid_v7}
    end
  end

  defp required_string(value, _field) when is_binary(value) and value != "", do: {:ok, value}
  defp required_string(_value, field), do: {:error, {:required_string, field}}

  defp optional_string(nil, _field), do: {:ok, nil}
  defp optional_string(value, _field) when is_binary(value) and value != "", do: {:ok, value}
  defp optional_string("", _field), do: {:ok, nil}
  defp optional_string(_value, field), do: {:error, {:optional_string, field}}

  defp json_object(value, _field) do
    with {:ok, value} <- JSON.stringify_keys(value),
         true <- JSON.json_object?(value) do
      {:ok, value}
    else
      _other -> {:error, :invalid_json_object}
    end
  end

  defp map_value(%{} = map, key) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  end

  defp map_value(_value, _key), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp malformed(reason) do
    OutboundError.new(:malformed, "invalid Gateway Delivery", %{reason: inspect(reason)})
  end
end
