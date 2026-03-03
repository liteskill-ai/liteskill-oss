defmodule Mix.Tasks.Gen.JrPrompt do
  @shortdoc "Generate the JSON-render AI prompt from the JS catalog"
  @moduledoc """
  Bundles the JS component catalog with esbuild, then runs it with Node
  to produce `priv/json_render_prompt.txt`.

      $ mix gen.jr_prompt
  """

  use Boundary, classify_to: Liteskill
  use Mix.Task

  @impl true
  def run(_args) do
    Mix.Task.run("esbuild", ["json_render_prompt"])

    mjs_path = Path.join(File.cwd!(), "priv/json_render_prompt_gen.mjs")

    case System.cmd("node", [mjs_path], cd: File.cwd!(), stderr_to_stdout: true) do
      {output, 0} ->
        Mix.shell().info(output)

      {output, code} ->
        Mix.raise("gen.jr_prompt failed (exit #{code}):\n#{output}")
    end
  end
end
