defmodule Ankole.Plugins.LarkAdapter.CardKit.ErrorPolicy do
  @moduledoc false

  alias FeishuOpenAPI.Error

  @stream_closed_codes [200_850, 300_309]
  @missing_card_codes [200_740, 200_750]
  @plain_text_fallback_codes [
    230_072,
    230_075,
    10_002,
    200_220,
    200_860,
    300_301,
    300_302,
    300_303,
    300_305,
    300_307,
    300_312,
    300_313,
    300_314,
    300_315,
    300_121,
    300_122
  ]
  @operator_codes [999_916_63, 999_916_64, 999_916_68, 300_311]

  @type action ::
          :retry
          | :reopen_stream
          | :replace_card
          | :plain_text_fallback
          | :operator_action_required

  @spec action(term()) :: action()
  def action(%Error{code: code}) when code in @stream_closed_codes, do: :reopen_stream
  def action(%Error{code: code}) when code in @missing_card_codes, do: :replace_card

  def action(%Error{code: code}) when code in @plain_text_fallback_codes,
    do: :plain_text_fallback

  def action(%Error{code: code}) when code in @operator_codes, do: :operator_action_required

  def action(%Error{code: 230_099, msg: message}) when is_binary(message) do
    if message
       |> String.downcase()
       |> String.contains?("errcode: 200780") do
      :plain_text_fallback
    else
      :operator_action_required
    end
  end

  def action(%Error{code: code}) when code in [200_810, 300_120, 300_317], do: :retry
  def action(%Error{code: code}) when code in [:transport, :rate_limited], do: :retry
  def action(%Error{http_status: status}) when status in [408, 409, 425, 429], do: :retry
  def action(%Error{http_status: status}) when is_integer(status) and status >= 500, do: :retry
  def action(%Error{}), do: :operator_action_required
  def action(reason) when reason in [:timeout, :closed, :econnrefused, :enetunreach], do: :retry
  def action({:error, reason}), do: action(reason)
  def action(_reason), do: :operator_action_required

  @spec provider_error(term()) :: map()
  def provider_error(%Error{} = error) do
    %{
      "code" => error.code,
      "message" => error.msg,
      "http_status" => error.http_status,
      "log_id" => error.log_id,
      "recovery_action" => Atom.to_string(action(error))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  def provider_error(reason) do
    %{
      "reason" => inspect(reason, limit: 20),
      "recovery_action" => Atom.to_string(action(reason))
    }
  end
end
