defmodule Ankole.Conversations.ToolCatalog do
  @moduledoc "Builds the tool contract for the current run from its owning declarations."

  alias Ankole.Conversations.{Tool, Tools}

  @worker_path Path.expand(
                 "../../../../kernel/proto/ankole/runtime_fabric/v1/worker_tools.json",
                 __DIR__
               )
  @external_resource @worker_path
  @worker_tools @worker_path |> File.read!() |> Ankole.JSON.decode!()

  def for_run(run) do
    context = run.spec.request_context
    profiles = context["custom_model_profiles"] || []
    templates = Enum.filter(run.context.agent_plugins, & &1["has_workspace_template"])

    client =
      Enum.flat_map(
        [
          Tools.Session,
          Tools.Schedule,
          Tools.Jobs,
          Tools.Workflow,
          Tools.Skill,
          Tools.Web,
          Ankole.Conversations.Presentation
        ],
        fn owner ->
          Enum.map(owner.declarations(), &Map.put(&1, "executor", owner))
        end
      )
      |> Enum.reject(fn tool ->
        (tool["name"] in ["set_channel_standing_orders", "read_channel_history"] and
           is_nil(run.event.signal_channel_id)) or
          (tool["name"] in ["submit_result", "sleep"] and run.kind != :workflow_task) or
          (tool["name"] == "web_search" and
             get_in(context, ["ai_agent", "provider_hosted", "web_search"]) == true)
      end)
      |> Enum.map(&specialize(&1, profiles, templates, context, run.session_id))

    worker = Enum.map(@worker_tools, &Map.put(&1, "executor", :worker))

    tools =
      worker ++
        client ++ Enum.map(Tools.Message.declarations(), &Map.put(&1, "executor", Tools.Message))

    tools =
      if run.kind == :workflow_task,
        do:
          Enum.filter(
            tools,
            &(&1["name"] in ~w(web_search web_fetch create_background_job show_background_job_details send_message_to_background_job stop_background_job sleep submit_result))
          ),
        else: tools

    hosted =
      hosted_tools(run)

    route = context["ambient"] || %{}

    {tools, hosted} =
      cond do
        route["action"] == "FOREGROUND_REPLY" ->
          {Enum.filter(tools, & &1["read_only"]),
           Enum.filter(hosted, &(&1["type"] in ["brain", "web_search"]))}

        route["authority"] == "NONE" and route["action"] == "NEW_WORK" ->
          {[], []}

        true ->
          {tools, hosted}
      end

    {Enum.map(tools, &Tool.new(Map.delete(&1, "executor"), &1["executor"])), hosted}
  end

  defp hosted_tools(run) do
    Enum.flat_map(run.spec[:hosted_tools] || [], fn tool ->
      cond do
        run.kind == :workflow_task and tool["type"] == "brain" ->
          [
            %{
              "type" => "brain",
              "operations" => ~w(recall get_page)
            }
          ]

        run.kind == :workflow_task and tool["type"] != "web_search" ->
          []

        tool["type"] == "brain" ->
          [Map.put(tool, "inject", true)]

        true ->
          [tool]
      end
    end)
  end

  def wire(tools), do: Enum.map(tools, & &1.schema)

  def find(run, call) do
    Enum.find(run.tools, fn tool ->
      tool.name == call["name"] and
        namespace(tool.schema["namespace"]) == namespace(call["namespace"])
    end)
  end

  def namespace(value) when value in [nil, "", "functions"], do: "functions"
  def namespace(value), do: value

  defp specialize(tool, profiles, templates, context, session_id) do
    tool =
      if tool["name"] in ["workflow", "create_background_job"] and profiles != [] do
        names = profiles |> Enum.map(& &1["name"]) |> Enum.sort()

        description =
          "Available custom model profiles: " <>
            Enum.map_join(
              Enum.sort_by(profiles, & &1["name"]),
              ", ",
              &"#{&1["name"]} (#{&1["description"]})"
            ) <>
            ". Omit model_profile to use the default #{if tool["name"] == "workflow", do: "primary", else: "coding"} profile."

        tool
        |> update_in(
          ["parameters", "properties"],
          &Map.put(&1, "model_profile", %{"type" => "string", "enum" => names})
        )
        |> Map.update!(
          "description",
          &Regex.replace(
            ~r/No custom model profile is available; omit model_profile to use the default (coding|primary) profile\./,
            &1,
            description
          )
        )
      else
        tool
      end

    cond do
      # A turn in a schedule's execution session sees only that schedule. It
      # may pause it to stop the work; resuming, rerunning or rewriting stays
      # with the owner conversation.
      tool["name"] == "cron" and Ankole.Schedule.cron_execution_schedule_id(session_id) != nil ->
        tool
        |> Map.put(
          "description",
          "Inspect or pause the recurring schedule that runs this conversation (list/get/runs/pause). When its task says to stop once a condition is met and you find the condition met, pause it. You cannot create, change, resume, run or remove schedules here."
        )
        |> put_in(["parameters", "properties", "action", "enum"], ~w(list get runs pause))
        |> update_in(["parameters", "properties"], &Map.take(&1, ~w(action name limit)))

      tool["name"] == "create_background_job" and templates != [] ->
        templates = Enum.sort_by(templates, & &1["id"])

        description =
          "Available workspace templates: " <>
            Enum.map_join(
              templates,
              ", ",
              &"#{&1["id"]} (#{Ankole.Conversations.Prompt.catalog_line(&1["description"], 400)})"
            ) <> ". Omit workspace_template_id to use no template."

        tool
        |> put_in(["parameters", "properties", "workspace_template_id"], %{
          "type" => "string",
          "enum" => Enum.map(templates, & &1["id"])
        })
        |> Map.update!(
          "description",
          &String.replace(
            &1,
            "No workspace template is available; omit workspace_template_id.",
            description
          )
        )

      tool["name"] == "submit_result" ->
        put_in(tool, ["parameters", "properties", "result"], context["schema"])

      true ->
        tool
    end
  end
end
