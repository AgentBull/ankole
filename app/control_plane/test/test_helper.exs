real_llm_exclude =
  case System.get_env("ANKOLE_REAL_LLM_E2E") do
    "1" -> []
    _ -> [real_llm: true]
  end

ExUnit.start(exclude: [:regenerate_golden | real_llm_exclude])

if Process.whereis(Ankole.Repo) do
  Ecto.Adapters.SQL.Sandbox.mode(Ankole.Repo, :manual)
end
