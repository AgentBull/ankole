%{
  configs: [
    %{
      name: "default",
      files: %{
        included:
          ["lib/", "../../plugins/*/lib/"] ++
            if(System.get_env("ANKOLE_EDITION") == "saas",
              do: ["../../internals/control_plane/lib/", "../../internals/plugins/*/lib/"],
              else: []
            ),
        excluded: []
      },
      strict: true,
      requires: ["credo/*.ex"],
      checks: %{
        enabled: [
          {ExSlop.Check.Warning.DualKeyAccess, []},
          {ExSlop.Check.Warning.BlanketRescue, []},
          {ExSlop.Check.Warning.RescueWithoutReraise, []},
          {ExSlop.Check.Warning.QueryInEnumMap, []},
          {ExSlop.Check.Warning.RepoAllThenFilter, []},
          {Ankole.Credo.AppendInLoop, []},
          {Credo.Check.Refactor.Nesting, [max_nesting: 4]},
          {Credo.Check.Refactor.CyclomaticComplexity, [max_complexity: 20]}
        ]
      }
    }
  ]
}
