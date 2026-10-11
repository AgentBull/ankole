defmodule Ankole.Conversations.Tools.Skill do
  @behaviour Ankole.Conversations.Tool
  @moduledoc false
  @declarations Ankole.JSON.decode!(~S"""
                [
                {
                  "type": "function",
                  "name": "skill_view",
                  "description": "Read an enabled Skill file. In the main runtime, a background-job-only Skill returns routing guidance and rejects referenced resources; inside a background agent job, skill_view loads its full instructions. Read referenced files only when needed and resolve relative paths from the returned Skill directory. This tool cannot enable disabled Skills.",
                  "parameters": {
                    "type": "object",
                    "properties": {
                      "name": {
                        "type": "string",
                        "minLength": 1,
                        "description": "Enabled skill name to read."
                      },
                      "filePath": {
                        "description": "Skill-relative file path. Defaults to SKILL.md.",
                        "type": "string"
                      }
                    },
                    "required": [
                      "name"
                    ],
                    "additionalProperties": false
                  },
                  "execution_mode": "parallel",
                  "read_only": true,
                  "destructive": false
                }
                ]
                """)
  @impl true
  def normalize(_name, args), do: args

  @impl true
  def declarations, do: @declarations

  @impl true
  def execute(run, _call, args) do
    summary = Enum.find(run.context.skills, &(&1["skill_name"] == args["name"]))
    runtime = get_in(summary || %{}, ["metadata", "ankole-runtime"]) || "any"

    cond do
      is_nil(summary) ->
        {:error, "skill is not enabled for this turn: #{args["name"]}"}

      runtime not in ["any", "main", "background_job"] ->
        {:error, "invalid ankole-runtime for Skill #{args["name"]}: #{runtime}"}

      runtime == "background_job" and args["filePath"] not in [nil, "SKILL.md"] ->
        {:error,
         "This Skill runs in a background agent job. Referenced resources are not available in the main runtime."}

      runtime == "background_job" ->
        {:ok,
         Ankole.Conversations.Tools.result(
           %{"name" => args["name"], "path" => "SKILL.md"},
           text:
             Enum.join(
               [
                 "The enabled #{args["name"]} Skill is a background-task capability.",
                 "Do not execute it inline and do not try to read its operational body or referenced resources from the main agent.",
                 "Create a background agent job with create_background_job. Put the complete user request, constraints, paths, acceptance criteria, and an explicit instruction to use the #{args["name"]} Skill in the task.",
                 "The background agent job can load the complete enabled Skill and its resources with skill_view."
               ],
               "\n"
             )
         )}

      true ->
        with {:ok, skill} <-
               Ankole.AIAgent.Library.skill_view(run.agent_uid, args["name"], args["filePath"]) do
          directory = Ankole.SignalsGateway.ActorRuntime.WorkerBootstrap.skill_directory(summary)
          path = args["filePath"] || "SKILL.md"

          text =
            Enum.join(
              [
                "<skill name=\"#{escape(args["name"])}\" location=\"#{escape(skill["skill_uri"])}\" directory=\"#{escape(directory)}\" runtime=\"#{runtime}\">",
                "<external_content source=\"skill\">",
                skill["content"],
                "</external_content>",
                "</skill>"
              ],
              "\n"
            )

          {:ok,
           Ankole.Conversations.Tools.result(%{"name" => args["name"], "path" => path},
             text: text
           )}
        end
    end
  end

  defp escape(text),
    do:
      text
      |> String.replace("&", "&amp;")
      |> String.replace("\"", "&quot;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")
end
