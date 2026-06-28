defmodule Ankole.ActorRuntime.CommitCoordinator.Payload do
  @moduledoc false

  alias Ankole.AIAgent.Schemas.LlmTurn

  def unwrap_body(%{"body" => %{"type" => type} = body}, type), do: fetch_map!(body, type)
  def unwrap_body(%{body: %{"type" => type} = body}, type), do: fetch_map!(body, type)
  def unwrap_body(%{body: %{type: type} = body}, type), do: fetch_map!(body, type)

  def unwrap_body(%{} = map, type),
    do: fetch_map(map, type) || fetch_map(map, String.to_atom(type)) || map

  def fetch_actor_agent_uid(turn_ref),
    do: turn_ref |> fetch_map!("actor") |> fetch_text!("agent_uid") |> normalize_uid()

  def fetch_actor_session_id(turn_ref),
    do: turn_ref |> fetch_map!("actor") |> fetch_text!("session_id")

  def fetch_turn_id(turn_ref), do: fetch_text!(turn_ref, "llm_turn_id")

  def fetch_text!(map, key) do
    case fetch_text(map, key) do
      value when is_binary(value) and value != "" -> value
      _value -> raise ArgumentError, "missing #{key}"
    end
  end

  def fetch_text(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  end

  def fetch_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  end

  def fetch_map!(map, key) do
    case fetch_map(map, key) do
      %{} = value -> value
      _value -> raise ArgumentError, "missing #{key}"
    end
  end

  def fetch_map(map, key) when is_map(map) and is_atom(key), do: Map.get(map, key)

  def fetch_map(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  end

  def fetch_list(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      values when is_list(values) -> values
      _value -> []
    end
  end

  def fetch_int!(map, key) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      value when is_integer(value) -> value
      value when is_binary(value) -> String.to_integer(value)
      _value -> raise ArgumentError, "missing #{key}"
    end
  end

  def proposal_reply_text(proposal, %LlmTurn{}) do
    case fetch_map(proposal, "reply") do
      %{} = reply ->
        case fetch_text(reply, "text") do
          text when is_binary(text) ->
            case String.trim(text) do
              "" -> {:error, :proposal_reply_text_missing}
              _text -> {:ok, text}
            end

          _value ->
            {:error, :proposal_reply_text_missing}
        end

      nil ->
        {:error, :proposal_reply_missing}
    end
  end

  def proposal_reply_attachments(proposal) do
    proposal
    |> fetch_map("reply")
    |> case do
      %{} = reply ->
        reply
        |> fetch_list("attachments")
        |> Enum.map(&normalize_reply_attachment/1)
        |> collect_results()

      _value ->
        {:ok, []}
    end
  end

  def assistant_content(text, attachments) do
    [%{"type" => "text", "text" => text}] ++
      Enum.map(attachments, &Map.put(&1, "type", "attachment"))
  end

  def proposal_summary(proposal) do
    %{
      "reply" => fetch_map(proposal, "reply") || %{},
      "messages" => fetch_list(proposal, "messages")
    }
    |> maybe_put("summary", fetch_map(proposal, "summary"))
  end

  def proposal_usage(proposal, %LlmTurn{usage: usage}) do
    case fetch_map(proposal, "usage_json") do
      %{} = usage -> usage
      _value -> usage || %{}
    end
  end

  def proposal_tool_results(proposal) do
    fetch_list(proposal, "tool_results_json")
  end

  def proposal_provider_metadata(proposal, %LlmTurn{provider_metadata: provider_metadata}) do
    provider_metadata = provider_metadata || %{}

    case fetch_map(proposal, "provider_metadata_json") do
      %{} = proposal_metadata -> Map.merge(provider_metadata, proposal_metadata)
      _value -> provider_metadata
    end
  end

  def worker_turn_error(payload) do
    %{
      code: fetch_text(payload, "code") || "worker_turn_error",
      message: fetch_text(payload, "message") || "worker turn failed",
      details: fetch_map(payload, "details_json") || %{}
    }
  end

  def collect_results(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, value}, {:ok, acc} -> {:cont, {:ok, [value | acc]}}
      {:error, _reason} = error, _acc -> {:halt, error}
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_reply_attachment(%{} = attachment) do
    with {:ok, relative_path} <- attachment_user_files_relative_path(attachment) do
      {:ok,
       %{
         "agent_computer_path" => "/workspace/user-files/#{relative_path}",
         "user_files_relative_path" => relative_path
       }
       |> maybe_put("name", optional_text_field(attachment, "name"))
       |> maybe_put("mime_type", optional_text_field(attachment, "mime_type"))
       |> maybe_put("xxh3_128", optional_text_field(attachment, "xxh3_128"))
       |> maybe_put("size", optional_non_negative_integer(attachment, "size"))}
    end
  end

  defp normalize_reply_attachment(_attachment), do: {:error, :invalid_reply_attachment}

  defp attachment_user_files_relative_path(attachment) do
    path =
      optional_text_field(attachment, "user_files_relative_path") ||
        optional_text_field(attachment, "agent_computer_path") ||
        optional_text_field(attachment, "path")

    cond do
      is_binary(path) and String.starts_with?(path, "/workspace/user-files/") ->
        normalize_user_files_relative_path(
          String.replace_prefix(path, "/workspace/user-files/", "")
        )

      is_binary(path) ->
        normalize_user_files_relative_path(path)

      true ->
        {:error, :reply_attachment_path_missing}
    end
  end

  defp normalize_user_files_relative_path(path) do
    normalized =
      path
      |> String.replace("\\", "/")
      |> String.replace(~r{/+}, "/")
      |> String.trim_leading("/")

    segments = String.split(normalized, "/", trim: true)

    case segments != [] and Enum.all?(segments, &valid_relative_segment?/1) do
      true -> {:ok, Enum.join(segments, "/")}
      false -> {:error, :invalid_reply_attachment_path}
    end
  end

  defp valid_relative_segment?(segment), do: segment not in ["", ".", ".."]

  defp optional_text_field(map, key) do
    case fetch_text(map, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          text -> text
        end

      _value ->
        nil
    end
  end

  defp optional_non_negative_integer(map, key) do
    case fetch_value(map, key) do
      value when is_integer(value) and value >= 0 -> value
      _value -> nil
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_uid(value) when is_binary(value), do: String.downcase(value)
end
