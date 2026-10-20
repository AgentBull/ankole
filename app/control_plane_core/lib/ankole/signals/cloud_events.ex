defmodule Ankole.Signals.CloudEvents do
  @moduledoc "Structured JSON CloudEvents source adapter with endpoint-specific routing."

  import Ecto.Query
  alias Ankole.Signals.Target, as: ExecutionTarget
  alias Ankole.Ecto.JSONPayload
  alias Ankole.Principals.WorkAccess
  alias Ankole.Signals
  alias Ankole.Signals.{Binding, BindingFilters}

  @doc "Routes a validated CloudEvent to each matching subscription in one transaction."
  def accept_in_tx(repo, endpoint, event, now) do
    with {:ok, event} <- normalize(event) do
      reference = "webhook-endpoint://#{endpoint.id}"

      repo.all(
        from(b in Binding,
          where:
            b.adapter == "cloudevents" and b.config_ref == ^reference and b.enabled and
              is_nil(b.unavailable_reason),
          order_by: [asc: b.agent_uid, asc: b.name]
        )
      )
      |> Enum.reduce_while({:ok, []}, fn binding, {:ok, accepted} ->
        case BindingFilters.match_event?(binding.filters, event, binding) do
          :no_match ->
            {:cont, {:ok, accepted}}

          :match ->
            with {:ok, target} <- target(binding, event),
                 {:ok, signal} <-
                   Signals.accept_in_tx(repo, %{
                     producer: :external,
                     source: event["source"],
                     id: event["id"],
                     type: event["type"],
                     subject: event["subject"],
                     time: event["time"] || now,
                     data: event["data"],
                     extensions:
                       Map.drop(event, ~w(specversion id source type subject time data)),
                     target: target,
                     sender: nil,
                     authorization: WorkAccess.service()
                   }) do
              {:cont, {:ok, [signal | accepted]}}
            else
              error -> {:halt, error}
            end

          error ->
            {:halt, error}
        end
      end)
      |> case do
        {:ok, accepted} -> {:ok, accepted |> Enum.reverse() |> Enum.uniq_by(& &1.id)}
        error -> error
      end
    end
  end

  @doc "Validates the supported structured JSON event fields without altering producer identity."
  def normalize(%{"specversion" => "1.0"} = event) do
    with :ok <- extensions(event),
         :ok <- context_text(event["id"]),
         :ok <- uri_reference(event["source"]),
         :ok <- context_text(event["type"]),
         :ok <- optional_context_text(event["subject"]),
         :ok <- optional_time(event["time"]),
         {:ok, data} <- JSONPayload.normalize(Map.get(event, "data", %{})) do
      {:ok, Map.put(event, "data", data)}
    else
      {:error, _} = error -> error
    end
  end

  def normalize(_event), do: {:error, :invalid_cloudevent}

  defp extensions(event) do
    event
    |> Map.drop(~w(specversion id source type subject time data))
    |> Enum.reduce_while(:ok, fn {name, value}, :ok ->
      case extension(name, value) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp extension("data_base64", _value), do: {:error, :unsupported_cloudevent_binary_data}
  defp extension(name, nil) when name in ~w(datacontenttype dataschema), do: :ok
  defp extension("dataschema", value) when is_binary(value), do: absolute_uri(value)

  defp extension("datacontenttype", value) when is_binary(value) do
    case {valid_string?(value), Plug.Conn.Utils.media_type(value)} do
      {true, {:ok, _, _, _}} -> :ok
      _ -> {:error, :invalid_cloudevent}
    end
  end

  defp extension(name, _value) when name in ~w(datacontenttype dataschema),
    do: {:error, :invalid_cloudevent}

  defp extension(name, value) when is_binary(name) do
    if Regex.match?(~r/\A[a-z0-9]+\z/, name) and extension_value?(value),
      do: :ok,
      else: {:error, :invalid_cloudevent_extension}
  end

  defp extension(_name, _value), do: {:error, :invalid_cloudevent_extension}
  defp extension_value?(nil), do: true
  defp extension_value?(value) when is_boolean(value), do: true

  defp extension_value?(value) when is_integer(value),
    do: value >= -2_147_483_648 and value <= 2_147_483_647

  defp extension_value?(value) when is_binary(value), do: valid_string?(value)
  defp extension_value?(_value), do: false

  defp target(%Binding{agent_uid: uid, target: target}, _event)
       when map_size(target) == 1 do
    case ExecutionTarget.parse(target) do
      {:conversation, id} ->
        {:ok, %{agent_uid: uid, conversation_id: id}}

      {:session, key} ->
        if Ankole.Sessions.Key.routable?(key),
          do: {:ok, %{agent_uid: uid, session_id: key}},
          else: {:error, :invalid_signal_target}

      :error ->
        {:error, :invalid_signal_target}
    end
  end

  defp target(_binding, _event), do: {:error, :invalid_signal_target}

  defp context_text(value) when is_binary(value) do
    if value != "" and valid_string?(value),
      do: :ok,
      else: {:error, :invalid_cloudevent}
  end

  defp context_text(_value), do: {:error, :invalid_cloudevent}

  defp valid_string?(value) do
    String.valid?(value) and not Regex.match?(~r/[\x00-\x1f\x7f-\x9f]/u, value) and
      not Enum.any?(String.to_charlist(value), fn codepoint ->
        codepoint in 0xFDD0..0xFDEF or rem(codepoint, 0x10000) in [0xFFFE, 0xFFFF]
      end)
  end

  defp uri_reference(value) do
    with :ok <- context_text(value),
         false <- Regex.match?(~r/%(?![0-9a-fA-F]{2})/, value),
         {:ok, _} <- URI.new(value) do
      :ok
    else
      _ -> {:error, :invalid_cloudevent}
    end
  end

  defp absolute_uri(value) do
    with :ok <- uri_reference(value),
         %URI{scheme: scheme} when is_binary(scheme) <- URI.parse(value) do
      :ok
    else
      _ -> {:error, :invalid_cloudevent}
    end
  end

  defp optional_context_text(nil), do: :ok
  defp optional_context_text(value), do: context_text(value)
  defp optional_time(nil), do: :ok

  defp optional_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _, _} -> :ok
      _ -> {:error, :invalid_cloudevent}
    end
  end

  defp optional_time(_value), do: {:error, :invalid_cloudevent}
end
