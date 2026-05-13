defmodule BullXWeb.FeishuCardCallbackController do
  @moduledoc false

  use BullXWeb, :controller

  def create(conn, %{"channel_id" => channel_id} = params) do
    payload = Map.delete(params, "channel_id")

    with {:ok, source} <- BullX.Gateway.Sources.fetch_enabled("feishu", channel_id),
         {:ok, result} <- Feishu.Channel.handle_card_action_callback(payload, source) do
      json(conn, card_action_response(result))
    else
      {:challenge, challenge} ->
        json(conn, %{"challenge" => challenge})

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{"error" => safe_error(reason)})
    end
  end

  defp card_action_response({:ignored, reason}) do
    %{
      "msg" => "success",
      "ignored" => to_string(reason)
    }
  end

  defp card_action_response(:accepted), do: %{"msg" => "success"}
  defp card_action_response(%{} = result), do: result
  defp card_action_response(_result), do: %{"msg" => "success"}

  defp safe_error(%{"message" => message}) when is_binary(message), do: message
  defp safe_error(%{safe_message: message}) when is_binary(message), do: message
  defp safe_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_error(_reason), do: "invalid Feishu card callback"
end
