defmodule BullXDiscord.ApplicationCommands do
  @moduledoc """
  Discord native application command definitions and safe reconciliation.
  """

  alias BullXDiscord.{Config, Error}

  @owned_names ~w(ping preauth web_auth ask)

  @spec desired_commands() :: [map()]
  def desired_commands do
    [
      %{
        name: "ping",
        description: "Check BullX Discord connectivity",
        type: 1
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
        type: 1
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

  @spec sync(Config.t()) :: {:ok, map()} | {:error, map()}
  def sync(%Config{application_commands: %{sync_policy: "off"}}) do
    {:ok, %{status: "skipped", reason: "disabled"}}
  end

  def sync(%Config{} = config) do
    Config.with_bot(config, fn ->
      config.application_command_api.global_commands(snowflake(config.application_id))
    end)
    |> case do
      {:ok, commands} -> reconcile(commands, config)
      {:error, error} -> {:error, Error.map(error)}
    end
  end

  defp reconcile(existing_commands, config) when is_list(existing_commands) do
    existing_by_name = Map.new(existing_commands, &{command_name(&1), &1})
    desired_by_name = Map.new(desired_commands(), &{&1.name, &1})

    with {:ok, created, edited} <- upsert_commands(desired_by_name, existing_by_name, config),
         {:ok, deleted} <- delete_removed_commands(desired_by_name, existing_commands, config) do
      {:ok,
       %{
         status: "synced",
         created: created,
         edited: edited,
         deleted: deleted
       }}
    end
  end

  defp upsert_commands(desired_by_name, existing_by_name, config) do
    desired_by_name
    |> Enum.reduce_while({:ok, [], []}, fn {name, desired}, {:ok, created, edited} ->
      case Map.fetch(existing_by_name, name) do
        {:ok, existing} ->
          edit_if_changed(existing, desired, config, created, edited)

        :error ->
          create_command(desired, config, created, edited)
      end
    end)
  end

  defp edit_if_changed(existing, desired, config, created, edited) do
    case command_payload(existing) == command_payload(desired) do
      true ->
        {:cont, {:ok, created, edited}}

      false ->
        Config.with_bot(config, fn ->
          config.application_command_api.edit_global_command(
            snowflake(config.application_id),
            snowflake(command_id(existing)),
            desired
          )
        end)
        |> case do
          {:ok, _command} -> {:cont, {:ok, created, [desired.name | edited]}}
          {:error, error} -> {:halt, {:error, Error.map(error)}}
        end
    end
  end

  defp create_command(desired, config, created, edited) do
    Config.with_bot(config, fn ->
      config.application_command_api.create_global_command(
        snowflake(config.application_id),
        desired
      )
    end)
    |> case do
      {:ok, _command} -> {:cont, {:ok, [desired.name | created], edited}}
      {:error, error} -> {:halt, {:error, Error.map(error)}}
    end
  end

  defp delete_removed_commands(desired_by_name, existing_commands, config) do
    existing_commands
    |> Enum.filter(fn command ->
      name = command_name(command)
      name in @owned_names and not Map.has_key?(desired_by_name, name)
    end)
    |> Enum.reduce_while({:ok, []}, fn command, {:ok, deleted} ->
      Config.with_bot(config, fn ->
        config.application_command_api.delete_global_command(
          snowflake(config.application_id),
          snowflake(command_id(command))
        )
      end)
      |> case do
        :ok -> {:cont, {:ok, [command_name(command) | deleted]}}
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

  defp field(%{} = map, key) when is_atom(key),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

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
