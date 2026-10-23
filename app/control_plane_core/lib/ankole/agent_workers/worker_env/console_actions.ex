defmodule Ankole.AgentWorkers.WorkerEnv.ConsoleActions do
  @moduledoc "Runs operator variable actions through the WorkerEnv owner."
  use Ash.Resource.Actions.Implementation
  alias Ankole.AgentWorkers.WorkerEnv
  alias Ankole.Errors

  @impl true
  def run(input, opts, _context) do
    scope = Keyword.fetch!(opts, :scope)
    input |> execute(scope) |> Errors.wrap(&describe/1)
  end

  defp execute(%{action: %{name: :console_list}}, :global),
    do: list(WorkerEnv.console_list_global())

  defp execute(%{action: %{name: :console_list}}, :tenant),
    do: list(WorkerEnv.console_list_tenant())

  defp execute(%{action: %{name: :console_list_for_agent}, arguments: %{agent_uid: uid}}, _),
    do: list(WorkerEnv.console_list_for_agent(uid))

  defp execute(%{action: %{name: :console_put}, arguments: %{name: name}} = input, :global),
    do: item(WorkerEnv.console_put_global(name, attrs(input)))

  defp execute(%{action: %{name: :console_put}, arguments: %{name: name}} = input, :tenant),
    do: item(WorkerEnv.console_put_tenant(name, attrs(input)))

  defp execute(
         %{action: %{name: :console_put_for_agent}, arguments: %{agent_uid: uid, name: name}} =
           input,
         _
       ),
       do: item(WorkerEnv.console_put_for_agent(uid, name, attrs(input)))

  defp execute(%{action: %{name: :console_delete}, arguments: %{name: name}}, :global),
    do: item(WorkerEnv.console_delete_global(name))

  defp execute(%{action: %{name: :console_delete}, arguments: %{name: name}}, :tenant),
    do: item(WorkerEnv.console_delete_tenant(name))

  defp execute(
         %{action: %{name: :console_delete_for_agent}, arguments: %{agent_uid: uid, name: name}},
         _
       ),
       do: item(WorkerEnv.console_delete_for_agent(uid, name))

  defp execute(%{action: %{name: :console_decrypt}, arguments: %{name: name}}, :global),
    do: decrypted(WorkerEnv.console_decrypt_global(name), name)

  defp execute(%{action: %{name: :console_decrypt}, arguments: %{name: name}}, :tenant),
    do: decrypted(WorkerEnv.console_decrypt_tenant(name), name)

  defp execute(
         %{action: %{name: :console_decrypt_for_agent}, arguments: %{agent_uid: uid, name: name}},
         _
       ),
       do: decrypted(WorkerEnv.console_decrypt_for_agent(uid, name), name)

  defp attrs(input),
    do:
      input.arguments
      |> Map.take([:value, :secret, :description])
      |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)

  defp list({:ok, items}), do: {:ok, %{worker_envs: items}}
  defp list(error), do: error
  defp item({:ok, item}), do: {:ok, %{worker_env: item}}
  defp item(error), do: error
  defp decrypted({:ok, value}, name), do: {:ok, %{decrypted_value: %{name: name, value: value}}}
  defp decrypted(error, _), do: error

  defp describe(reason) when reason in [:not_found, :agent_not_found],
    do: Errors.Invalid.NotFound.exception(resource: WorkerEnv.ConsoleItem)

  defp describe({:invalid_worker_env_name, _}),
    do:
      {"The name must match [A-Za-z_][A-Za-z0-9_]*",
       [%{path: "name", message: "has invalid format"}]}

  defp describe({:reserved_worker_env_name, name}),
    do: {"#{name} is reserved by the Worker runtime", [%{path: "name", message: "is reserved"}]}

  defp describe(:not_encrypted), do: {"This variable is not encrypted", []}

  defp describe(:invalid_worker_env_value),
    do: {"A string value is required", [%{path: "value", message: "is required"}]}

  defp describe(_), do: nil
end
