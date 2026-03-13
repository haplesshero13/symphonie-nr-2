defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.{Codex.Subagent, Linear.Client, OpenRouter, PathSafety}

  @linear_graphql_tool "linear_graphql"
  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.
  """
  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @linear_graphql_tool ->
        execute_linear_graphql(arguments, opts)

      "spawn_claude" ->
        execute_spawn_agent(:claude, arguments, opts)

      "spawn_gemini" ->
        execute_spawn_agent(:gemini, arguments, opts)

      "spawn_codex" ->
        execute_spawn_agent(:codex, arguments, opts)

      "openrouter_complete" ->
        execute_openrouter_complete(arguments, opts)

      "check_quotas" ->
        execute_check_quotas(opts)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "name" => @linear_graphql_tool,
        "description" => @linear_graphql_description,
        "inputSchema" => @linear_graphql_input_schema
      },
      %{
        "name" => "spawn_claude",
        "description" => "Launch Claude Code CLI on a subtask. Best for research, web lookups, file analysis, and writing.",
        "inputSchema" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["task"],
          "properties" => %{
            "task" => %{
              "type" => "string",
              "description" => "The task description to send to Claude Code."
            },
            "workspace_subdir" => %{
              "type" => "string",
              "description" => "Optional subdirectory within the workspace to run in."
            }
          }
        }
      },
      %{
        "name" => "spawn_gemini",
        "description" => "Launch Gemini CLI on a subtask. Best for code generation, large-context analysis, and general-purpose tasks.",
        "inputSchema" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["task"],
          "properties" => %{
            "task" => %{
              "type" => "string",
              "description" => "The task description to send to Gemini CLI."
            },
            "workspace_subdir" => %{
              "type" => "string",
              "description" => "Optional subdirectory within the workspace to run in."
            }
          }
        }
      },
      %{
        "name" => "spawn_codex",
        "description" => "Launch a sub-Codex session on a subtask. Best for focused coding tasks.",
        "inputSchema" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["task"],
          "properties" => %{
            "task" => %{
              "type" => "string",
              "description" => "The task description to send to the sub-Codex session."
            },
            "workspace_subdir" => %{
              "type" => "string",
              "description" => "Optional subdirectory within the workspace to run in."
            }
          }
        }
      },
      %{
        "name" => "openrouter_complete",
        "description" => "One-shot LLM call via OpenRouter. Cheap and fast, good for summaries, classification, and quick analysis.",
        "inputSchema" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["prompt"],
          "properties" => %{
            "prompt" => %{
              "type" => "string",
              "description" => "The prompt to send to the LLM."
            },
            "model" => %{
              "type" => "string",
              "description" => "OpenRouter model identifier. Defaults to anthropic/claude-3.5-sonnet."
            }
          }
        }
      },
      %{
        "name" => "check_quotas",
        "description" => "Query provider availability before delegating work. Returns per-provider quota and availability status.",
        "inputSchema" => %{
          "type" => "object",
          "additionalProperties" => false,
          "properties" => %{}
        }
      }
    ]
  end

  defp execute_spawn_agent(provider, arguments, opts) do
    task = get_string_arg(arguments, "task")

    if is_nil(task) or String.trim(task) == "" do
      failure_response(%{"error" => %{"message" => "spawn_#{provider} requires a non-empty `task` string."}})
    else
      with {:ok, workspace} <- resolve_workspace(arguments, opts) do
        run_subagent(provider, task, workspace, opts)
      else
        {:error, :no_workspace} ->
          failure_response(%{"error" => %{"message" => "No workspace available for sub-agent execution."}})

        {:error, reason} ->
          failure_response(%{"error" => %{"message" => "Invalid workspace_subdir: #{inspect(reason)}."}})
      end
    end
  end

  defp run_subagent(provider, task, workspace, opts) do
    subagent_runner = Keyword.get(opts, :subagent_runner, &default_subagent_runner/3)

    case subagent_runner.(provider, task, workspace) do
      {:ok, %{output: output, exit_code: 0}} ->
        success_response(output)

      {:ok, %{output: output, exit_code: code}} ->
        failure_response(%{
          "error" => %{
            "message" => "Sub-agent exited with code #{code}.",
            "exit_code" => code,
            "output" => output
          }
        })

      {:error, reason} ->
        failure_response(%{"error" => %{"message" => "Sub-agent failed: #{inspect(reason)}"}})
    end
  end

  defp default_subagent_runner(:claude, task, workspace), do: Subagent.run_claude(task, workspace)
  defp default_subagent_runner(:gemini, task, workspace), do: Subagent.run_gemini(task, workspace)
  defp default_subagent_runner(:codex, task, workspace), do: Subagent.run_codex(task, workspace)

  defp execute_openrouter_complete(arguments, opts) do
    prompt = get_string_arg(arguments, "prompt")
    model = arguments |> get_string_arg("model") |> trim_to_nil()
    openrouter_client = Keyword.get(opts, :openrouter_client, &OpenRouter.complete/2)

    if is_nil(prompt) or String.trim(prompt) == "" do
      failure_response(%{"error" => %{"message" => "openrouter_complete requires a non-empty `prompt` string."}})
    else
      model_opts = if model, do: [model: model], else: []

      case openrouter_client.(prompt, model_opts) do
        {:ok, content} ->
          success_response(content)

        {:error, reason} ->
          failure_response(%{"error" => %{"message" => "OpenRouter completion failed: #{inspect(reason)}"}})
      end
    end
  end

  defp execute_check_quotas(opts) do
    openrouter_quota_checker = Keyword.get(opts, :openrouter_quota_checker, &OpenRouter.check_quota/0)

    openrouter_status =
      case openrouter_quota_checker.() do
        {:ok, data} -> %{"available" => true, "details" => data}
        {:error, reason} -> %{"available" => false, "error" => inspect(reason)}
      end

    claude_available = System.find_executable("claude") != nil
    gemini_available = System.find_executable("gemini") != nil
    codex_available = System.find_executable("codex") != nil

    payload = %{
      "openrouter" => openrouter_status,
      "claude" => %{"available" => claude_available},
      "gemini" => %{"available" => gemini_available},
      "codex" => %{"available" => codex_available}
    }

    success_response(encode_payload(payload))
  end

  defp resolve_workspace(arguments, opts) do
    base_workspace = Keyword.get(opts, :workspace)
    subdir = get_string_arg(arguments, "workspace_subdir")

    cond do
      is_nil(base_workspace) ->
        {:error, :no_workspace}

      is_nil(subdir) or String.trim(subdir) == "" ->
        {:ok, base_workspace}

      true ->
        validate_workspace_subdir(base_workspace, subdir)
    end
  end

  defp validate_workspace_subdir(base_workspace, subdir) do
    if Path.type(subdir) == :absolute do
      {:error, :absolute_subdir_not_allowed}
    else
      check_subdir_within_workspace(base_workspace, subdir)
    end
  end

  defp check_subdir_within_workspace(base_workspace, subdir) do
    resolved_path = Path.join(base_workspace, subdir)
    expanded_base = Path.expand(base_workspace)
    base_prefix = expanded_base <> "/"

    with {:ok, canonical_base} <- PathSafety.canonicalize(expanded_base),
         {:ok, canonical_resolved} <- PathSafety.canonicalize(Path.expand(resolved_path)) do
      canonical_base_prefix = canonical_base <> "/"

      cond do
        canonical_resolved == canonical_base ->
          {:error, :resolves_to_workspace_root}

        String.starts_with?(canonical_resolved <> "/", canonical_base_prefix) ->
          {:ok, canonical_resolved}

        String.starts_with?(Path.expand(resolved_path) <> "/", base_prefix) ->
          {:error, :symlink_escape}

        true ->
          {:error, :outside_workspace}
      end
    else
      {:error, {:path_canonicalize_failed, _path, reason}} ->
        {:error, {:path_unreadable, reason}}
    end
  end

  defp trim_to_nil(nil), do: nil

  defp trim_to_nil(str) when is_binary(str) do
    case String.trim(str) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp get_string_arg(arguments, key) when is_map(arguments) do
    case Map.get(arguments, key) || Map.get(arguments, String.to_existing_atom(key)) do
      value when is_binary(value) -> value
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp get_string_arg(_arguments, _key), do: nil

  defp success_response(output) when is_binary(output) do
    dynamic_tool_response(true, output)
  end

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            {:ok, query, variables}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    dynamic_tool_response(success, encode_payload(response))
  end

  defp failure_response(payload) do
    dynamic_tool_response(false, encode_payload(payload))
  end

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`linear_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:invalid_variables) do
    %{
      "error" => %{
        "message" => "`linear_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Linear GraphQL tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end
end
