%{
  configs: [
    %{
      name: "default",
      files: %{
        included:
          [
            "lib/",
            "../control_plane_core/lib/",
            "../../plugins/*/lib/",
            "../../libs/im_transport/lib/",
            "../../libs/feishu_protocol/lib/"
          ] ++
            if(System.get_env("ANKOLE_EDITION") == "saas",
              do: ["../../internals/control_plane/lib/", "../../internals/plugins/*/lib/"],
              else: []
            ),
        excluded: []
      },
      strict: true,
      requires: ["credo/*.ex"],
      checks: %{
        # `mix credo --strict` runs the Credo default check set plus `extra`.
        # Each check in `disabled` had the given number of findings across the
        # control plane, core, plugins, and shared libraries when the default
        # set was switched on (2026-10-21). Enable a check again in the change
        # that removes its findings.
        disabled: [
          # 628
          {Credo.Check.Design.AliasUsage, []},
          # 401
          {Credo.Check.Readability.AliasOrder, []},
          # 76
          {Credo.Check.Readability.WithSingleClause, []},
          # 52
          {Credo.Check.Refactor.RedundantWithClauseResult, []},
          # 28
          {Credo.Check.Refactor.CondStatements, []},
          # 18
          {Credo.Check.Readability.LargeNumbers, []},
          # 18
          {Credo.Check.Refactor.FunctionArity, []},
          # 16
          {Credo.Check.Readability.PreferImplicitTry, []},
          # 11
          {Credo.Check.Refactor.MapJoin, []},
          # 7
          {Credo.Check.Refactor.WithClauses, []},
          # 6
          {Credo.Check.Refactor.Apply, []},
          # 5
          {Credo.Check.Refactor.NegatedConditionsWithElse, []},
          # 5
          {Credo.Check.Warning.MissedMetadataKeyInLoggerConfig, []},
          # 4
          {Credo.Check.Readability.ModuleDoc, []},
          # 3
          {Credo.Check.Readability.UnnecessaryAliasExpansion, []},
          # 3
          {Credo.Check.Refactor.MatchInCondition, []},
          # 2
          {Credo.Check.Warning.StructFieldAmount, []},
          # 1
          {Credo.Check.Consistency.ExceptionNames, []},
          # 1
          {Credo.Check.Consistency.SpaceAroundOperators, []},
          # 1
          {Credo.Check.Readability.ParenthesesOnZeroArityDefs, []},
          # 1
          {Credo.Check.Refactor.RejectReject, []},
          # 1
          {Credo.Check.Warning.UnusedEnumOperation, []}
        ],
        extra: [
          {ExSlop.Check.Warning.DualKeyAccess, []},
          {ExSlop.Check.Warning.BlanketRescue, []},
          {ExSlop.Check.Warning.RescueWithoutReraise, []},
          {ExSlop.Check.Warning.QueryInEnumMap, []},
          {ExSlop.Check.Warning.RepoAllThenFilter, []},
          {Ankole.Credo.AppendInLoop, []},
          {Ankole.Credo.AshActions, []},
          {Credo.Check.Refactor.Nesting, [max_nesting: 4]},
          {Credo.Check.Refactor.CyclomaticComplexity, [max_complexity: 20]}
        ]
      }
    }
  ]
}
