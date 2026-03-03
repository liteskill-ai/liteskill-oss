%Doctor.Config{
  ignore_modules: [
    # Phoenix-generated boilerplate
    LiteskillWeb,
    LiteskillWeb.Endpoint,
    LiteskillWeb.Router,
    LiteskillWeb.Gettext,
    LiteskillWeb.Telemetry,
    Liteskill.Repo,
    Liteskill.Mailer,
    # Inspect protocol implementations
    ~r/^Inspect\./,
    # Postgrex generated types
    ~r/^Liteskill\.Repo\.PostgrexTypes/
  ],
  ignore_paths: [
    ~r"lib/mix/",
    ~r"deps/"
  ],
  min_module_doc_coverage: 0,
  min_module_spec_coverage: 0,
  min_overall_doc_coverage: 40,
  min_overall_spec_coverage: 0,
  min_overall_moduledoc_coverage: 90,
  moduledoc_required: true,
  raise: true,
  reporter: Doctor.Reporters.Full,
  struct_type_spec_required: false,
  umbrella: false
}
