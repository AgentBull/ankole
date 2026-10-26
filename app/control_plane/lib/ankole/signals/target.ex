defmodule Ankole.Signals.Target do
  @moduledoc "Parses a Signal destination without resolving its Agent or access."
  alias Ankole.Sessions.Key

  def parse({:conversation, id}), do: conversation(id)

  def parse(target) when is_map(target) do
    case {Ankole.Attrs.get(target, :conversation_id), Ankole.Attrs.get(target, :session_id)} do
      {id, nil} when not is_nil(id) -> conversation(id)
      {nil, key} -> session(key)
      _ -> :error
    end
  end

  def parse(_target), do: :error

  defp conversation(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:conversation, id}
      :error -> :error
    end
  end

  defp session(key) do
    case Key.parse(key) do
      {:conversation, id} -> {:conversation, id}
      :error -> :error
      _ -> {:session, key}
    end
  end
end
