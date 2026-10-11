defmodule Ankole.Repo.Migrations.ScopeReceivedFilesToChats do
  use Ecto.Migration

  require Logger

  def up do
    execute(fn ->
      repo = repo()

      %{rows: rows} =
        repo.query!("""
        SELECT tenant_id, agent_uid, path, signal_channel_id FROM agent_files
        WHERE source = 'inbound' AND starts_with(path, 'inbox/')
          AND signal_channel_id IS NOT NULL AND signal_channel_id <> ''
        """)

      for [tenant_id, agent_uid, old_path, channel_id] <- rows do
        channel_segment = URI.encode(channel_id, &(&1 == ?: or URI.char_unreserved?(&1)))

        channel_segment =
          if channel_segment in [".", ".."],
            do: String.replace(channel_segment, ".", "%2E"),
            else: channel_segment

        new_path = "chats/#{channel_segment}/#{old_path}"

        if byte_size(new_path) > 1024 or byte_size(channel_segment) > 255 do
          raise Ecto.MigrationError,
            message: "received file does not fit its conversation drive path: #{old_path}"
        end

        %{rows: conflicts} =
          repo.query!(
            """
            SELECT path FROM agent_files
            WHERE tenant_id = $1 AND agent_uid = $2 AND path <> $3
              AND (path = $4 OR starts_with(path, $4 || '/') OR starts_with($4, path || '/'))
            """,
            [tenant_id, agent_uid, old_path, new_path]
          )

        if conflicts != [] do
          raise Ecto.MigrationError,
            message:
              "received file conflicts with an existing conversation drive path: #{new_path}"
        end

        repo.query!(
          "UPDATE agent_files SET path = $4 WHERE tenant_id = $1 AND agent_uid = $2 AND path = $3",
          [tenant_id, agent_uid, old_path, new_path]
        )
      end

      %{rows: [[unknown_count]]} =
        repo.query!("""
        SELECT count(*) FROM agent_files
        WHERE source = 'inbound' AND starts_with(path, 'inbox/')
          AND (signal_channel_id IS NULL OR signal_channel_id = '')
        """)

      if unknown_count > 0 do
        Logger.warning(
          "#{unknown_count} received drive files have no source channel; kept at their existing inbox paths"
        )
      end
    end)
  end

  def down do
    raise Ecto.MigrationError,
      message: "conversation drive paths cannot be merged into shared inbox paths"
  end
end
