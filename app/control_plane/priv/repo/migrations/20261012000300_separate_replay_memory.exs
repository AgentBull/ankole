defmodule Ankole.Repo.Migrations.SeparateReplayMemory do
  use Ecto.Migration

  def up do
    migrate_batch(nil)

    # alpha.1 Agent input contains its opening pack without brain_injection.
    # Keep that stored input and move the conversation claim before deleting it.
    execute """
    UPDATE ai_gateway_messages AS message
    SET metadata = COALESCE(message.metadata, '{}'::jsonb) ||
                   '{"brain_context_pack_claimed": true}'::jsonb
    FROM ai_gateway_conversations AS conversation
    WHERE message.conversation_id = conversation.id
      AND message.tenant_id = conversation.tenant_id
      AND (conversation.metadata ? 'brain_context_pack_at'
        OR conversation.metadata ? 'brain_context_pack_event')
    """

    execute "UPDATE ai_gateway_conversations SET metadata = metadata - 'brain_context_pack_at' - 'brain_context_pack_event'"
  end

  # The previous representation changed user content. Rollback would recreate
  # that contract for new rows, so restore a database backup when rolling back.
  def down,
    do:
      raise(Ecto.MigrationError, "separate replay memory requires a database backup to roll back")

  defp migrate_batch(after_id) do
    %{rows: rows} =
      repo().query!(
        """
        SELECT id, tenant_id, content, metadata FROM ai_gateway_messages
        WHERE metadata ? 'brain_injection' AND ($1::uuid IS NULL OR id > $1::uuid)
        ORDER BY id LIMIT 500
        """,
        [after_id]
      )

    Enum.each(rows, fn [id, tenant, content, metadata] ->
      {content, metadata} = separate(content, metadata)

      repo().query!(
        "UPDATE ai_gateway_messages SET content = $1, metadata = $2 WHERE id = $3 AND tenant_id = $4",
        [content, metadata, id, tenant]
      )
    end)

    case List.last(rows) do
      [id | _] -> migrate_batch(id)
      nil -> :ok
    end
  end

  @doc false
  def separate(content, metadata) do
    injection = metadata["brain_injection"] || %{}
    positions = injection["items"] || []
    count = metadata["request_item_count"] || length(content)

    if Enum.any?(positions, &(&1 < 0 or &1 >= count)),
      do: raise("invalid stored Brain pack position")

    pack = Enum.map(positions, &Enum.fetch!(content, &1))
    {content, pointers} = separate_pointers(content, injection["environment"])

    content =
      content
      |> Enum.with_index()
      |> Enum.reject(fn {_, i} -> i in positions end)
      |> Enum.map(&elem(&1, 0))

    metadata =
      metadata
      |> Map.delete("brain_injection")
      |> Map.merge(%{
        "brain_context_pack" => pack,
        "brain_context_pack_claimed" => true,
        "brain_pointer_lines" => pointers,
        "request_item_count" => count - length(positions)
      })

    # Only legacy rows need insertion positions. New packs use a fixed prefix.
    metadata =
      if positions == Enum.take(Enum.to_list(0..count), length(positions)),
        do: metadata,
        else: Map.put(metadata, "brain_context_pack_positions", positions)

    {content, metadata}
  end

  defp separate_pointers(content, nil), do: {content, []}

  defp separate_pointers(content, %{
         "item_index" => i,
         "part_index" => p,
         "offset" => offset,
         "length" => size
       }) do
    message = Enum.fetch!(content, i)
    parts = Map.fetch!(message, "content")
    part = Enum.fetch!(parts, p)
    text = Map.fetch!(part, "text")
    injected = binary_part(text, offset, size)

    original =
      binary_part(text, 0, offset) <>
        binary_part(text, offset + size, byte_size(text) - offset - size)

    parts =
      if original == "",
        do: List.delete_at(parts, p),
        else: List.replace_at(parts, p, Map.put(part, "text", original))

    pointers = injected |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "memory: "))
    {List.replace_at(content, i, Map.put(message, "content", parts)), pointers}
  end
end
