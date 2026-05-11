defmodule BullXGateway.Delivery do
  @moduledoc """
  Outbound delivery carrier. One struct value describes one intended external
  effect (`:send`, `:edit`, or `:stream`) produced by Runtime and consumed by
  the Gateway egress runtime.

  The struct is JSON-serializable except for the streaming Enumerable: a
  `:stream` delivery carries an `Enumerable.t()` as `content`, which lives only
  in the BEAM process. On crash the Enumerable is gone; Runtime + Oban is
  responsible for re-issuing outstanding deliveries.
  """

  alias BullXGateway.Delivery.{Content, Outcome}

  @type adapter :: atom()
  @type channel_id :: String.t()
  @type channel :: {adapter(), channel_id()}
  @type op :: :send | :edit | :stream

  @type t :: %__MODULE__{
          id: String.t(),
          op: op(),
          channel: channel(),
          scope_id: String.t(),
          thread_id: String.t() | nil,
          reply_to_external_id: String.t() | nil,
          target_external_id: String.t() | nil,
          content: Content.t() | Enumerable.t() | nil,
          caused_by_signal_id: String.t() | nil,
          extensions: map()
        }

  @enforce_keys [:id, :op, :channel, :scope_id]
  defstruct [
    :id,
    :op,
    :channel,
    :scope_id,
    :thread_id,
    :reply_to_external_id,
    :target_external_id,
    :content,
    :caused_by_signal_id,
    extensions: %{}
  ]

  @doc """
  Wrap an adapter delivery operation in the common Gateway telemetry span.

  Adapter modules still own transport-specific delivery behavior. The shared
  span keeps metadata and result classification consistent across adapters.
  """
  @spec telemetry_span(adapter(), t(), (-> term())) :: term()
  def telemetry_span(adapter, %__MODULE__{} = delivery, fun)
      when is_atom(adapter) and is_function(fun, 0) do
    :telemetry.span([:bullx, adapter, :delivery], telemetry_meta(delivery), fn ->
      result = fun.()
      {result, telemetry_result(result)}
    end)
  end

  @doc """
  Shape-validate a delivery struct before it is cast to a `ScopeWorker`.

  The check covers only intrinsic struct shape: the adapter callback is still
  responsible for adapter-specific validation. Stream Enumerables are accepted
  without inspection; the adapter consumes them inside `stream/3`.
  """
  @spec validate(term()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = delivery) do
    with :ok <- validate_id(delivery.id),
         :ok <- validate_op(delivery.op),
         :ok <- validate_channel(delivery.channel),
         :ok <- validate_scope_id(delivery.scope_id),
         :ok <- validate_thread_id(delivery.thread_id),
         :ok <- validate_optional_string(delivery.reply_to_external_id, :reply_to_external_id),
         :ok <- validate_op_fields(delivery),
         :ok <- validate_content(delivery),
         :ok <- validate_optional_string(delivery.caused_by_signal_id, :caused_by_signal_id),
         :ok <- validate_extensions(delivery.extensions) do
      :ok
    end
  end

  def validate(other), do: {:error, {:not_a_delivery, other}}

  defp validate_id(id) when is_binary(id) and id != "", do: :ok
  defp validate_id(_), do: {:error, :invalid_id}

  defp validate_op(op) when op in [:send, :edit, :stream], do: :ok
  defp validate_op(op), do: {:error, {:invalid_op, op}}

  defp validate_channel({adapter, channel_id})
       when is_atom(adapter) and is_binary(channel_id) and channel_id != "",
       do: :ok

  defp validate_channel(channel), do: {:error, {:invalid_channel, channel}}

  defp validate_scope_id(scope_id) when is_binary(scope_id) and scope_id != "", do: :ok
  defp validate_scope_id(_), do: {:error, :invalid_scope_id}

  defp validate_thread_id(nil), do: :ok
  defp validate_thread_id(thread_id) when is_binary(thread_id) and thread_id != "", do: :ok
  defp validate_thread_id(_), do: {:error, :invalid_thread_id}

  defp validate_optional_string(nil, _field), do: :ok

  defp validate_optional_string(value, _field) when is_binary(value) and value != "", do: :ok

  defp validate_optional_string(_value, field), do: {:error, {:invalid_field, field}}

  defp validate_op_fields(%__MODULE__{op: :edit, target_external_id: tid}) do
    case tid do
      tid when is_binary(tid) and tid != "" -> :ok
      _ -> {:error, :missing_target_external_id}
    end
  end

  defp validate_op_fields(%__MODULE__{target_external_id: nil}), do: :ok

  defp validate_op_fields(%__MODULE__{target_external_id: tid}) when is_binary(tid) and tid != "",
    do: :ok

  defp validate_op_fields(_), do: {:error, :invalid_target_external_id}

  defp validate_content(%__MODULE__{op: :stream, content: nil}),
    do: {:error, :missing_stream_content}

  defp validate_content(%__MODULE__{op: :stream, content: content}) do
    if stream_content?(content), do: :ok, else: {:error, :invalid_stream_content}
  end

  defp validate_content(%__MODULE__{op: :edit, content: nil}), do: :ok

  defp validate_content(%__MODULE__{op: :edit, content: %Content{} = content}),
    do: Content.validate(content)

  defp validate_content(%__MODULE__{op: :edit}), do: {:error, :invalid_content}

  defp validate_content(%__MODULE__{op: :send, content: %Content{} = content}),
    do: Content.validate(content)

  defp validate_content(%__MODULE__{op: :send}), do: {:error, :invalid_content}

  defp stream_content?(list) when is_list(list), do: true
  defp stream_content?(other), do: Enumerable.impl_for(other) != nil

  defp validate_extensions(extensions) when is_map(extensions), do: :ok
  defp validate_extensions(_), do: {:error, :invalid_extensions}

  defp telemetry_meta(%__MODULE__{} = delivery) do
    %{
      channel: delivery.channel,
      delivery_id: delivery.id,
      op: delivery.op,
      scope_id: delivery.scope_id
    }
  end

  defp telemetry_result({:ok, %Outcome{} = outcome}), do: %{outcome: outcome.status}
  defp telemetry_result({:error, %{"kind" => kind}}), do: %{outcome: :error, error_kind: kind}
  defp telemetry_result(_), do: %{outcome: :error}
end
