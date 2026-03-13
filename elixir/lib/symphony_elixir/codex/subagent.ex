defmodule SymphonyElixir.Codex.Subagent do
  @moduledoc """
  Spawns CLI sub-agents (Claude Code, GitHub Copilot, Codex) as subprocesses
  and collects their output.
  """

  require Logger

  @default_timeout_ms 600_000

  @spec run(String.t(), String.t(), Path.t(), keyword()) ::
          {:ok, %{output: String.t(), exit_code: integer()}} | {:error, term()}
  def run(command, task, workspace, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    try do
      case System.cmd("bash", ["-lc", command],
             cd: workspace,
             input: task,
             stderr_to_stdout: true,
             timeout: timeout_ms
           ) do
        {output, exit_code} ->
          {:ok, %{output: output, exit_code: exit_code}}
      end
    rescue
      e in ErlangError ->
        {:error, {:subagent_failed, Exception.message(e)}}
    end
  end

  @spec run_claude(String.t(), Path.t(), keyword()) ::
          {:ok, %{output: String.t(), exit_code: integer()}} | {:error, term()}
  def run_claude(task, workspace, opts \\ []) do
    run("claude --print -p \"$(cat)\"", task, workspace, opts)
  end

  @spec run_copilot(String.t(), Path.t(), keyword()) ::
          {:ok, %{output: String.t(), exit_code: integer()}} | {:error, term()}
  def run_copilot(task, workspace, opts \\ []) do
    run("copilot", task, workspace, opts)
  end

  @spec run_codex(String.t(), Path.t(), keyword()) ::
          {:ok, %{output: String.t(), exit_code: integer()}} | {:error, term()}
  def run_codex(task, workspace, opts \\ []) do
    codex_command = Keyword.get(opts, :codex_command, "codex")
    run(codex_command, task, workspace, opts)
  end
end
