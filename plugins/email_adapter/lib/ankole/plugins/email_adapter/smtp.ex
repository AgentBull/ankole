defmodule Ankole.Plugins.EmailAdapter.Smtp do
  @moduledoc """
  Sends one message through `gen_smtp_client`.

  The session opens in one step and delivers in another, so a failure before
  `DATA` is clearly safe to retry, while a failure during delivery may have
  reached the server and answers `:unknown`.
  """

  alias Ankole.Plugins.EmailAdapter.Config

  @spec deliver(Config.Runtime.t(), String.t(), [String.t()], binary()) ::
          {:ok, String.t()} | :unknown | {:error, term()}
  def deliver(%Config.Runtime{} = config, from, recipients, body)
      when is_binary(from) and is_list(recipients) and recipients != [] and is_binary(body) do
    options = Config.smtp_options(config)

    case :gen_smtp_client.open(options) do
      {:ok, socket} ->
        result = :gen_smtp_client.deliver(socket, {from, recipients, body})
        close(socket)
        delivery_result(result)

      {:error, type, failure} ->
        {:error, {:smtp_open, type, failure}}

      {:error, reason} ->
        {:error, {:smtp_options, reason}}
    end
  end

  defp delivery_result({:ok, receipt}) when is_binary(receipt), do: {:ok, String.trim(receipt)}
  defp delivery_result({:ok, receipts}) when is_list(receipts), do: {:ok, inspect(receipts)}

  defp delivery_result({:error, {kind, _detail}})
       when kind in [:network_failure, :unexpected_response],
       do: :unknown

  defp delivery_result({:error, failure}), do: {:error, {:smtp_deliver, failure}}

  defp close(socket) do
    :gen_smtp_client.close(socket)
  catch
    _kind, _reason -> :ok
  end
end
