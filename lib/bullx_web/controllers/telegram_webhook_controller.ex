defmodule BullXWeb.TelegramWebhookController do
  use BullXWeb, :controller

  alias BullXGateway.AdapterRegistry
  alias BullXTelegram.{Channel, Config, Error}

  @secret_header "x-telegram-bot-api-secret-token"

  def update(conn, %{"channel_id" => channel_id} = params) do
    with :ok <- validate_channel_id(channel_id),
         {:ok, entry} <- AdapterRegistry.lookup({:telegram, channel_id}),
         {:ok, config} <- Config.normalize({:telegram, channel_id}, entry.config),
         :ok <- require_webhook_mode(config),
         :ok <- verify_secret(conn, config),
         {:ok, update} <- update_payload(params),
         {:ok, result} <- dispatch_update(config, update) do
      json(conn, %{ok: true, result: result})
    else
      {:error, :unsafe_channel_id} ->
        not_found(conn)

      :error ->
        not_found(conn)

      {:error, :not_webhook} ->
        not_found(conn)

      {:error, :invalid_secret} ->
        conn |> put_status(:unauthorized) |> json(%{ok: false})

      {:error, :invalid_payload} ->
        conn |> put_status(:bad_request) |> json(%{ok: false})

      {:error, %{} = error} ->
        conn |> put_status(:internal_server_error) |> json(%{ok: false, error: error})

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{ok: false, error: Error.map(reason)})
    end
  end

  def update(conn, _params), do: not_found(conn)

  defp validate_channel_id(channel_id) do
    case BullXWeb.Sessions.route_safe_channel_id?(channel_id) do
      true -> :ok
      false -> {:error, :unsafe_channel_id}
    end
  end

  defp require_webhook_mode(%Config{transport: %{mode: "webhook"}}), do: :ok
  defp require_webhook_mode(%Config{}), do: {:error, :not_webhook}

  defp verify_secret(conn, %Config{transport: %{secret_token: expected}})
       when is_binary(expected) do
    conn
    |> get_req_header(@secret_header)
    |> case do
      [provided | _] -> secure_compare(provided, expected)
      [] -> false
    end
    |> case do
      true -> :ok
      false -> {:error, :invalid_secret}
    end
  end

  defp verify_secret(_conn, %Config{}), do: {:error, :invalid_secret}

  defp secure_compare(provided, expected)
       when byte_size(provided) == byte_size(expected) do
    Plug.Crypto.secure_compare(provided, expected)
  end

  defp secure_compare(_provided, _expected), do: false

  defp update_payload(%{"update_id" => _} = params), do: {:ok, params}
  defp update_payload(%{"_json" => %{"update_id" => _} = update}), do: {:ok, update}
  defp update_payload(_params), do: {:error, :invalid_payload}

  defp dispatch_update(%Config{} = config, update) do
    case Channel.handle_update(config, update) do
      {:ok, result} -> {:ok, result}
      {:error, error} -> {:error, error}
      other -> {:ok, other}
    end
  catch
    :exit, reason -> {:error, {:channel_unavailable, reason}}
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{ok: false})
  end
end
