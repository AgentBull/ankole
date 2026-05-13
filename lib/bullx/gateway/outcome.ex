defmodule BullX.Gateway.Outcome do
  @moduledoc """
  Terminal transport outcome for an external Gateway Delivery.
  """

  alias BullX.Gateway.{Delivery, JSON}

  @statuses [:sent, :degraded, :failed]

  @enforce_keys [:delivery_id, :generation, :status, :external_message_ids, :warnings]
  defstruct [
    :delivery_id,
    :generation,
    :status,
    :primary_external_id,
    :error,
    external_message_ids: [],
    warnings: []
  ]

  @type status :: :sent | :degraded | :failed

  @type t :: %__MODULE__{
          delivery_id: String.t(),
          generation: non_neg_integer(),
          status: status(),
          external_message_ids: [String.t()],
          primary_external_id: String.t() | nil,
          warnings: [String.t()],
          error: map() | nil
        }

  @spec from_adapter(Delivery.t(), map()) :: {:ok, t()} | {:error, map()}
  def from_adapter(%Delivery{} = delivery, %{} = attrs) do
    with {:ok, attrs} <- JSON.stringify_keys(attrs),
         {:ok, status} <- success_status(Map.get(attrs, "status")),
         {:ok, external_message_ids} <- string_list(Map.get(attrs, "external_message_ids") || []),
         {:ok, primary_external_id} <- optional_string(Map.get(attrs, "primary_external_id")),
         {:ok, warnings} <- string_list(Map.get(attrs, "warnings") || []),
         outcome <-
           %__MODULE__{
             delivery_id: Map.get(attrs, "delivery_id") || delivery.id,
             generation: Map.get(attrs, "generation") || delivery.generation,
             status: status,
             external_message_ids: external_message_ids,
             primary_external_id: primary_external_id,
             warnings: warnings
           } do
      validate(outcome)
    else
      _other -> {:error, contract_error("adapter returned invalid delivery outcome")}
    end
  end

  def from_adapter(_delivery, _attrs),
    do: {:error, contract_error("adapter returned invalid delivery outcome")}

  @spec failed(Delivery.t(), map(), keyword()) :: t()
  def failed(%Delivery{} = delivery, error, opts \\ []) when is_map(error) do
    %__MODULE__{
      delivery_id: delivery.id,
      generation: delivery.generation,
      status: :failed,
      external_message_ids: [],
      warnings: [],
      error: normalize_error(error, opts)
    }
  end

  @spec load(map()) :: {:ok, t()} | {:error, term()}
  def load(%{} = attrs) do
    with {:ok, attrs} <- JSON.stringify_keys(attrs),
         {:ok, delivery_id} <- required_string(Map.get(attrs, "delivery_id")),
         {:ok, generation} <- generation(Map.get(attrs, "generation")),
         {:ok, status} <- status(Map.get(attrs, "status")),
         {:ok, external_message_ids} <- string_list(Map.get(attrs, "external_message_ids") || []),
         {:ok, primary_external_id} <- optional_string(Map.get(attrs, "primary_external_id")),
         {:ok, warnings} <- string_list(Map.get(attrs, "warnings") || []),
         {:ok, error} <- optional_error(Map.get(attrs, "error")),
         outcome <-
           %__MODULE__{
             delivery_id: delivery_id,
             generation: generation,
             status: status,
             external_message_ids: external_message_ids,
             primary_external_id: primary_external_id,
             warnings: warnings,
             error: error
           } do
      validate(outcome)
    end
  end

  def load(_value), do: {:error, :invalid_outcome}

  @spec dump(t()) :: map()
  def dump(%__MODULE__{} = outcome) do
    %{
      "delivery_id" => outcome.delivery_id,
      "generation" => outcome.generation,
      "status" => Atom.to_string(outcome.status),
      "external_message_ids" => outcome.external_message_ids,
      "primary_external_id" => outcome.primary_external_id,
      "warnings" => outcome.warnings,
      "error" => outcome.error
    }
  end

  @spec terminal_status(t()) :: :succeeded | :dead_lettered
  def terminal_status(%__MODULE__{status: status}) when status in [:sent, :degraded],
    do: :succeeded

  def terminal_status(%__MODULE__{status: :failed}), do: :dead_lettered

  defp validate(%__MODULE__{status: :degraded, warnings: []}) do
    {:error, contract_error("degraded delivery outcome requires warnings")}
  end

  defp validate(%__MODULE__{status: :failed, error: error}) when not is_map(error) do
    {:error, contract_error("failed delivery outcome requires an error map")}
  end

  defp validate(%__MODULE__{} = outcome), do: {:ok, outcome}

  defp success_status(value) do
    case status(value) do
      {:ok, status} when status in [:sent, :degraded] -> {:ok, status}
      _other -> {:error, :invalid_success_status}
    end
  end

  defp status(value) when value in @statuses, do: {:ok, value}

  defp status(value) when is_binary(value) do
    case value do
      "sent" -> {:ok, :sent}
      "degraded" -> {:ok, :degraded}
      "failed" -> {:ok, :failed}
      _other -> {:error, :invalid_status}
    end
  end

  defp status(_value), do: {:error, :invalid_status}

  defp normalize_error(error, opts) do
    error
    |> JSON.stringify_keys()
    |> case do
      {:ok, error} when is_map(error) -> error
      _other -> %{"kind" => "unknown", "message" => "delivery failed"}
    end
    |> put_attempts_exhausted(Keyword.get(opts, :attempts_exhausted?, false))
  end

  defp put_attempts_exhausted(error, true) do
    details =
      error
      |> Map.get("details", %{})
      |> Map.put("attempts_exhausted", true)

    Map.put(error, "details", details)
  end

  defp put_attempts_exhausted(error, _attempts_exhausted?), do: error

  defp optional_error(nil), do: {:ok, nil}

  defp optional_error(%{} = error) do
    with {:ok, error} <- JSON.stringify_keys(error),
         true <- JSON.json_object?(error) do
      {:ok, error}
    else
      _other -> {:error, :invalid_error}
    end
  end

  defp optional_error(_value), do: {:error, :invalid_error}

  defp string_list(values) when is_list(values) do
    case Enum.all?(values, &(is_binary(&1) and &1 != "")) do
      true -> {:ok, values}
      false -> {:error, :invalid_string_list}
    end
  end

  defp string_list(_values), do: {:error, :invalid_string_list}

  defp required_string(value) when is_binary(value) and value != "", do: {:ok, value}
  defp required_string(_value), do: {:error, :required_string}

  defp optional_string(nil), do: {:ok, nil}
  defp optional_string(value) when is_binary(value) and value != "", do: {:ok, value}
  defp optional_string(_value), do: {:error, :optional_string}

  defp generation(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp generation(_value), do: {:error, :invalid_generation}

  defp contract_error(message), do: %{"kind" => "contract", "message" => message}
end
