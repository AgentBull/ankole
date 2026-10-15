defmodule Ankole.Sessions.Key do
  @moduledoc "Constructs and parses persisted execution Session keys."

  def conversation(id), do: "conversation:#{id}"
  def cron(id), do: "cron:#{id}"
  def job(id), do: "job:#{id}"
  def workflow_task(id), do: "wf_task:#{id}"

  def parse(key) when is_binary(key) do
    if String.valid?(key) and String.trim(key) != "" and not String.contains?(key, <<0>>),
      do: parse_valid(key),
      else: :error
  end

  def parse(_key), do: :error

  def routable?(key) do
    case parse(key) do
      :error -> false
      {kind, _} when kind in [:job, :workflow_task] -> false
      _ -> true
    end
  end

  defp parse_valid("conversation:" <> id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:conversation, id}
      :error -> :error
    end
  end

  for {prefix, kind} <- [{"cron:", :cron}, {"job:", :job}, {"wf_task:", :workflow_task}] do
    defp parse_valid(unquote(prefix) <> id) do
      if String.trim(id) == "", do: :error, else: {unquote(kind), id}
    end
  end

  defp parse_valid(key), do: {:named, key}
end
