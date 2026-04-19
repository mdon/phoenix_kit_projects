%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/"],
        excluded: [~r"/_build/", ~r"/deps/"]
      },
      strict: true,
      checks: [
        {Credo.Check.Readability.ModuleDoc, false},
        {Credo.Check.Design.TagTODO, false},
        {Credo.Check.Refactor.CyclomaticComplexity, max_complexity: 15}
      ]
    }
  ]
}
