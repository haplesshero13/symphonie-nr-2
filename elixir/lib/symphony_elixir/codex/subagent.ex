defmodule SymphonyElixir.Codex.Subagent do
  @moduledoc """
  Spawns CLI sub-agents (Claude Code, Gemini CLI, Codex) as subprocesses
  and collects their output.
  """

  require Logger

  @default_timeout_ms 600_000

  @spec run(String.t(), [String.t()], Path.t(), keyword()) ::
          {:ok, %{output: String.t(), exit_code: integer()}} | {:error, term()}
  def run(executable, args, workspace, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    unless File.dir?(workspace) do
      {:error, {:invalid_workspace, :not_a_directory, workspace}}
    else
      Logger.debug("[Subagent] Starting #{executable} in #{workspace}")

      try do
        {output, exit_code} =
          System.cmd(executable, args,
            cd: workspace,
            stderr_to_stdout: true,
            timeout: timeout_ms
          )

        Logger.debug("[Subagent] #{executable} exited with code #{exit_code}")
        {:ok, %{output: output, exit_code: exit_code}}
      rescue
        e in [ErlangError, ArgumentError] ->
          Logger.warning("[Subagent] #{executable} failed: #{Exception.message(e)}")
          {:error, {:subagent_failed, Exception.message(e)}}
      end
    end
  end

  @spec run_claude(String.t(), Path.t(), keyword()) ::
          {:ok, %{output: String.t(), exit_code: integer()}} | {:error, term()}
  def run_claude(task, workspace, opts \\ []) do
    run("claude", ["--print", "-p", task], workspace, opts)
  end

  @spec run_gemini(String.t(), Path.t(), keyword()) ::
          {:ok, %{output: String.t(), exit_code: integer()}} | {:error, term()}
  def run_gemini(task, workspace, opts \\ []) do
    run("gemini", ["-p", task], workspace, opts)
  end

  @spec run_codex(String.t(), Path.t(), keyword()) ::
          {:ok, %{output: String.t(), exit_code: integer()}} | {:error, term()}
  def run_codex(task, workspace, opts \\ []) do
    codex_command = Keyword.get(opts, :codex_command, "codex")
    [executable | args] = String.split(codex_command, ~r/\s+/, trim: true)
    run(executable, args ++ [task], workspace, opts)
  end
end
