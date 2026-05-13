defmodule Discord.ApplicationCommands do
  @moduledoc """
  Discord native application command definitions and safe selective
  reconciliation against Discord.

  Sync policy values:

  - `"safe"` (default): list existing global commands, create missing
    BullX-owned commands, edit ones whose desired payload differs, and delete
    BullX-owned commands no longer in the desired set. Never bulk-overwrites
    the application's command list.
  - `"off"`: leaves the operator-managed command list alone.
  """

  alias Discord.{Error, Source}

  @owned_names ~w(ping preauth web_auth ask)

  @spec desired_commands() :: [map()]
  def desired_commands do
    [
      %{
        name: "ping",
        description: "Check BullX Discord connectivity",
        type: 1,
        options: []
      },
      %{
        name: "preauth",
        description: "Link this Discord account to BullX",
        type: 1,
        options: [
          %{
            name: "code",
            description: "BullX activation code",
            type: 3,
            required: true
          }
        ]
      },
      %{
        name: "web_auth",
        description: "Create a BullX web login code",
        type: 1,
        options: []
      },
      %{
        name: "ask",
        description: "Ask BullX in a Discord thread",
        type: 1,
        options: [
          %{
            name: "prompt",
            description: "Question or task for BullX",
            type: 3,
            required: true
          }
        ]
      }
    ]
  end

  @spec sync(Source.t()) :: {:ok, map()} | {:error, map()}
  def sync(%Source{application_commands: %{"sync_policy" => "off"}}) do
    {:ok, %{status: "skipped", reason: "disabled"}}
  end

  def sync(%Source{} = source) do
    case list_existing(source) do
      {:ok, commands} -> reconcile(commands, source)
      {:error, error} -> {:error, Error.map(error)}
    end
  end

  defp list_existing(%Source{} = source) do
    application_id = snowflake(source.application_id)

    Source.with_bot(source, fn ->
      source.application_command_api.global_commands(application_id)
    end)
  end

  defp reconcile(existing_commands, %Source{} = source) when is_list(existing_commands) do
    existing_by_name = Map.new(existing_commands, &{command_name(&1), &1})
    desired_by_name = Map.new(desired_commands(), &{&1.name, &1})

    with {:ok, created, edited} <- upsert_commands(desired_by_name, existing_by_name, source),
         {:ok, deleted} <- delete_removed_commands(desired_by_name, existing_commands, source) do
      {:ok,
       %{
         status: "synced",
         created: created,
         edited: edited,
         deleted: deleted
       }}
    end
  end

  defp reconcile(_other, _source),
    do: {:error, Error.unknown("Discord global_commands returned unexpected shape")}

  defp upsert_commands(desired_by_name, existing_by_name, %Source{} = source) do
    desired_by_name
    |> Enum.reduce_while({:ok, [], []}, fn {name, desired}, {:ok, created, edited} ->
      case Map.fetch(existing_by_name, name) do
        {:ok, existing} -> edit_if_changed(existing, desired, source, created, edited)
        :error -> create_command(desired, source, created, edited)
      end
    end)
  end

  defp edit_if_changed(existing, desired, %Source{} = source, created, edited) do
    case command_payload(existing) == command_payload(desired) do
      true ->
        {:cont, {:ok, created, edited}}

      false ->
        application_id = snowflake(source.application_id)
        command_id = snowflake(command_id(existing))

        Source.with_bot(source, fn ->
          source.application_command_api.edit_global_command(application_id, command_id, desired)
        end)
        |> case do
          {:ok, _command} -> {:cont, {:ok, created, [desired.name | edited]}}
          {:error, error} -> {:halt, {:error, Error.map(error)}}
        end
    end
  end

  defp create_command(desired, %Source{} = source, created, edited) do
    application_id = snowflake(source.application_id)

    Source.with_bot(source, fn ->
      source.application_command_api.create_global_command(application_id, desired)
    end)
    |> case do
      {:ok, _command} -> {:cont, {:ok, [desired.name | created], edited}}
      {:error, error} -> {:halt, {:error, Error.map(error)}}
    end
  end

  defp delete_removed_commands(desired_by_name, existing_commands, %Source{} = source) do
    existing_commands
    |> Enum.filter(fn command ->
      name = command_name(command)
      name in @owned_names and not Map.has_key?(desired_by_name, name)
    end)
    |> Enum.reduce_while({:ok, []}, fn command, {:ok, deleted} ->
      application_id = snowflake(source.application_id)
      command_id = snowflake(command_id(command))

      Source.with_bot(source, fn ->
        source.application_command_api.delete_global_command(application_id, command_id)
      end)
      |> case do
        :ok -> {:cont, {:ok, [command_name(command) | deleted]}}
        {:ok, _result} -> {:cont, {:ok, [command_name(command) | deleted]}}
        {:error, error} -> {:halt, {:error, Error.map(error)}}
      end
    end)
  end

  defp command_payload(command) do
    %{
      name: command_name(command),
      description: field(command, :description),
      type: field(command, :type) || 1,
      options: normalize_options(field(command, :options) || [])
    }
  end

  defp normalize_options(options) when is_list(options) do
    Enum.map(options, fn option ->
      %{
        name: field(option, :name),
        description: field(option, :description),
        type: field(option, :type),
        required: field(option, :required) == true
      }
    end)
  end

  defp normalize_options(_options), do: []

  defp command_name(command), do: field(command, :name)
  defp command_id(command), do: field(command, :id)

  defp field(%{} = map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp field(_value, _key), do: nil

  defp snowflake(value) when is_integer(value), do: value

  defp snowflake(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _other -> value
    end
  end

  defp snowflake(value), do: value
end
