defmodule MicrosoftOpenAPI.Error do
  @moduledoc "Microsoft Entra/Graph/Bot Connector and transport error."

  @type t :: %__MODULE__{
          reason: String.t() | atom(),
          status: integer() | nil,
          retry_after: non_neg_integer() | nil,
          raw: term()
        }

  defexception [:reason, :status, :retry_after, :raw]

  @impl true
  def message(%__MODULE__{reason: reason, status: status}) do
    "microsoft_openapi error: reason=#{inspect(reason)} status=#{inspect(status)}"
  end

  @spec retryable?(t()) :: boolean()
  def retryable?(%__MODULE__{reason: reason}) when reason in [:rate_limited, :transport], do: true
  def retryable?(%__MODULE__{status: status}) when is_integer(status) and status >= 500, do: true
  def retryable?(%__MODULE__{}), do: false

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%MicrosoftOpenAPI.Error{} = error, opts) do
      visible =
        [reason: error.reason, status: error.status, retry_after: error.retry_after]
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> then(fn fields ->
          if is_nil(error.raw), do: fields, else: fields ++ [raw: :redacted]
        end)

      concat(["#MicrosoftOpenAPI.Error<", to_doc(visible, opts), ">"])
    end
  end
end
