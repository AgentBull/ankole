defmodule Feishu.CardActionController do
  @moduledoc false

  use BullXWeb, :controller

  alias Feishu.Source
  alias FeishuOpenAPI.CardAction

  def callback(conn, %{"source_id" => source_id}) do
    with {:ok, source} <- Source.fetch_enabled_source(source_id),
         {:ok, verify_config} <- Source.card_action_verify_config(source),
         {:ok, body} <- raw_body(conn),
         {:ok, action} <- verify_card_action(verify_config, body, conn.req_headers),
         :ok <- accept_card_action(source, action) do
      json(conn, %{})
    else
      {:challenge, challenge} ->
        json(conn, %{"challenge" => challenge})

      {:error, error} ->
        error = Feishu.Error.map(error)

        conn
        |> put_status(error_status(error))
        |> json(%{"error" => error})
    end
  end

  defp raw_body(conn) do
    case conn.private[:raw_body] do
      body when is_binary(body) -> {:ok, body}
      _value -> {:error, Feishu.Error.payload("missing Feishu card-action callback body")}
    end
  end

  defp verify_card_action(verify_config, body, headers) do
    case CardAction.verify_and_decode(verify_config, body, headers) do
      {:ok, %CardAction{} = action} ->
        {:ok, action}

      {:challenge, challenge} ->
        {:challenge, challenge}

      {:error, reason} ->
        {:error,
         Feishu.Error.payload("invalid Feishu card-action callback", %{
           "reason" => safe_reason(reason)
         })}
    end
  end

  defp accept_card_action(%Source{} = source, %CardAction{} = action) do
    case BullX.EventBus.ChannelAdapter.accept_inbound("feishu", source, {:card_action, action}) do
      {:ok, _accepted} -> :ok
      :ignore -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp error_status(%{"kind" => "auth"}), do: 401
  defp error_status(%{"kind" => "rate_limit"}), do: 429
  defp error_status(%{"kind" => kind}) when kind in ["config", "network"], do: 503
  defp error_status(%{"kind" => kind}) when kind in ["payload", "unsupported"], do: 400
  defp error_status(_error), do: 500

  defp safe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason(reason) when is_binary(reason), do: reason
  defp safe_reason(reason), do: inspect(reason, limit: 3, printable_limit: 80)
end
