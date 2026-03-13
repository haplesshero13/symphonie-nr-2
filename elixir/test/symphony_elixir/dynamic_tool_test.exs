defmodule SymphonyElixir.Codex.DynamicToolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool

  test "tool_specs advertises the linear_graphql input contract" do
    specs = DynamicTool.tool_specs()
    linear_spec = Enum.find(specs, &(&1["name"] == "linear_graphql"))

    assert %{
             "description" => description,
             "inputSchema" => %{
               "properties" => %{
                 "query" => _,
                 "variables" => _
               },
               "required" => ["query"],
               "type" => "object"
             },
             "name" => "linear_graphql"
           } = linear_spec

    assert description =~ "Linear"
  end

  test "tool_specs includes sub-agent and openrouter tools" do
    specs = DynamicTool.tool_specs()
    names = Enum.map(specs, & &1["name"])

    assert "spawn_claude" in names
    assert "spawn_gemini" in names
    assert "spawn_codex" in names
    assert "openrouter_complete" in names
    assert "check_quotas" in names
  end

  test "unsupported tools return a failure payload with the supported tool list" do
    response = DynamicTool.execute("not_a_real_tool", %{})

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => ~s(Unsupported dynamic tool: "not_a_real_tool".),
               "supportedTools" => Enum.map(DynamicTool.tool_specs(), & &1["name"])
             }
           }

    assert response["contentItems"] == [
             %{
               "type" => "inputText",
               "text" => response["output"]
             }
           ]
  end

  test "linear_graphql returns successful GraphQL responses as tool text" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => "query Viewer { viewer { id } }",
          "variables" => %{"includeTeams" => false}
        },
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_123"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{"includeTeams" => false}, []}

    assert response["success"] == true
    assert Jason.decode!(response["output"]) == %{"data" => %{"viewer" => %{"id" => "usr_123"}}}
    assert response["contentItems"] == [%{"type" => "inputText", "text" => response["output"]}]
  end

  test "linear_graphql accepts a raw GraphQL query string" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        "  query Viewer { viewer { id } }  ",
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_456"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "linear_graphql ignores legacy operationName arguments" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }", "operationName" => "Viewer"},
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_789"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "linear_graphql passes multi-operation documents through unchanged" do
    test_pid = self()

    query = """
    query Viewer { viewer { id } }
    query Teams { teams { nodes { id } } }
    """

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => query},
        linear_client: fn forwarded_query, variables, opts ->
          send(test_pid, {:linear_client_called, forwarded_query, variables, opts})
          {:ok, %{"errors" => [%{"message" => "Must provide operation name if query contains multiple operations."}]}}
        end
      )

    assert_received {:linear_client_called, forwarded_query, %{}, []}
    assert forwarded_query == String.trim(query)
    assert response["success"] == false
  end

  test "linear_graphql rejects blank raw query strings even when using the default client" do
    response = DynamicTool.execute("linear_graphql", "   ")

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` requires a non-empty `query` string."
             }
           }
  end

  test "linear_graphql marks GraphQL error responses as failures while preserving the body" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "mutation BadMutation { nope }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{"errors" => [%{"message" => "Unknown field `nope`"}], "data" => nil}}
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "data" => nil,
             "errors" => [%{"message" => "Unknown field `nope`"}]
           }
  end

  test "linear_graphql marks atom-key GraphQL error responses as failures" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{errors: [%{message: "boom"}], data: nil}}
        end
      )

    assert response["success"] == false
  end

  test "linear_graphql validates required arguments before calling Linear" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"variables" => %{"commentId" => "comment-1"}},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` requires a non-empty `query` string."
             }
           }

    blank_query =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "   "},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when the query is blank")
        end
      )

    assert blank_query["success"] == false
  end

  test "linear_graphql rejects invalid argument types" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        [:not, :valid],
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
             }
           }
  end

  test "linear_graphql rejects invalid variables" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }", "variables" => ["bad"]},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when variables are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql.variables` must be a JSON object when provided."
             }
           }
  end

  test "linear_graphql formats transport and auth failures" do
    missing_token =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, :missing_linear_api_token} end
      )

    assert missing_token["success"] == false

    assert Jason.decode!(missing_token["output"]) == %{
             "error" => %{
               "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
             }
           }

    status_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, {:linear_api_status, 503}} end
      )

    assert Jason.decode!(status_error["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL request failed with HTTP 503.",
               "status" => 503
             }
           }

    request_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, {:linear_api_request, :timeout}} end
      )

    assert Jason.decode!(request_error["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL request failed before receiving a successful response.",
               "reason" => ":timeout"
             }
           }
  end

  test "linear_graphql formats unexpected failures from the client" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, :boom} end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL tool execution failed.",
               "reason" => ":boom"
             }
           }
  end

  test "spawn_claude succeeds and returns sub-agent output" do
    response =
      DynamicTool.execute(
        "spawn_claude",
        %{"task" => "summarise this repo"},
        workspace: "/tmp/test-workspace",
        subagent_runner: fn :claude, task, workspace ->
          assert task == "summarise this repo"
          assert workspace == "/tmp/test-workspace"
          {:ok, %{output: "Summary complete.", exit_code: 0}}
        end
      )

    assert response["success"] == true
    assert response["output"] == "Summary complete."
  end

  test "spawn_gemini succeeds and returns sub-agent output" do
    response =
      DynamicTool.execute(
        "spawn_gemini",
        %{"task" => "write tests"},
        workspace: "/tmp/test-workspace",
        subagent_runner: fn :gemini, _task, _workspace ->
          {:ok, %{output: "Tests written.", exit_code: 0}}
        end
      )

    assert response["success"] == true
    assert response["output"] == "Tests written."
  end

  test "spawn_codex succeeds and returns sub-agent output" do
    response =
      DynamicTool.execute(
        "spawn_codex",
        %{"task" => "refactor auth module"},
        workspace: "/tmp/test-workspace",
        subagent_runner: fn :codex, _task, _workspace ->
          {:ok, %{output: "Refactor done.", exit_code: 0}}
        end
      )

    assert response["success"] == true
    assert response["output"] == "Refactor done."
  end

  test "spawn_claude returns structured failure when sub-agent exits with non-zero code" do
    response =
      DynamicTool.execute(
        "spawn_claude",
        %{"task" => "do something"},
        workspace: "/tmp/test-workspace",
        subagent_runner: fn :claude, _task, _workspace ->
          {:ok, %{output: "something went wrong", exit_code: 1}}
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "Sub-agent exited with code 1.",
               "exit_code" => 1,
               "output" => "something went wrong"
             }
           }
  end

  test "spawn_claude returns structured failure when sub-agent errors" do
    response =
      DynamicTool.execute(
        "spawn_claude",
        %{"task" => "do something"},
        workspace: "/tmp/test-workspace",
        subagent_runner: fn :claude, _task, _workspace ->
          {:error, {:subagent_failed, "executable not found"}}
        end
      )

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "Sub-agent failed"
  end

  test "spawn_claude rejects blank task" do
    response =
      DynamicTool.execute(
        "spawn_claude",
        %{"task" => "   "},
        workspace: "/tmp/test-workspace",
        subagent_runner: fn _provider, _task, _workspace ->
          flunk("runner should not be called for blank task")
        end
      )

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "non-empty"
  end

  test "spawn_claude fails when no workspace is available" do
    response =
      DynamicTool.execute(
        "spawn_claude",
        %{"task" => "do something"},
        subagent_runner: fn _provider, _task, _workspace ->
          flunk("runner should not be called when there is no workspace")
        end
      )

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "No workspace available"
  end

  test "spawn_claude rejects workspace_subdir with path traversal" do
    response =
      DynamicTool.execute(
        "spawn_claude",
        %{"task" => "do something", "workspace_subdir" => "../../etc"},
        workspace: System.tmp_dir!(),
        subagent_runner: fn _provider, _task, _workspace ->
          flunk("runner should not be called for traversal subdir")
        end
      )

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "Invalid workspace_subdir"
  end

  test "spawn_claude rejects absolute workspace_subdir" do
    response =
      DynamicTool.execute(
        "spawn_claude",
        %{"task" => "do something", "workspace_subdir" => "/etc"},
        workspace: System.tmp_dir!(),
        subagent_runner: fn _provider, _task, _workspace ->
          flunk("runner should not be called for absolute subdir")
        end
      )

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "Invalid workspace_subdir"
  end

  test "openrouter_complete returns content on success" do
    response =
      DynamicTool.execute(
        "openrouter_complete",
        %{"prompt" => "hello"},
        openrouter_client: fn "hello", [] -> {:ok, "World."} end
      )

    assert response["success"] == true
    assert response["output"] == "World."
  end

  test "openrouter_complete passes model option when provided" do
    response =
      DynamicTool.execute(
        "openrouter_complete",
        %{"prompt" => "classify this", "model" => "openai/gpt-4o"},
        openrouter_client: fn "classify this", [model: "openai/gpt-4o"] -> {:ok, "positive"} end
      )

    assert response["success"] == true
    assert response["output"] == "positive"
  end

  test "openrouter_complete treats blank model as unset" do
    response =
      DynamicTool.execute(
        "openrouter_complete",
        %{"prompt" => "classify this", "model" => "   "},
        openrouter_client: fn "classify this", [] -> {:ok, "neutral"} end
      )

    assert response["success"] == true
    assert response["output"] == "neutral"
  end

  test "openrouter_complete returns failure on error" do
    response =
      DynamicTool.execute(
        "openrouter_complete",
        %{"prompt" => "hello"},
        openrouter_client: fn _prompt, _opts -> {:error, :missing_openrouter_api_key} end
      )

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "OpenRouter completion failed"
  end

  test "openrouter_complete rejects blank prompt" do
    response =
      DynamicTool.execute(
        "openrouter_complete",
        %{"prompt" => ""},
        openrouter_client: fn _prompt, _opts ->
          flunk("client should not be called for blank prompt")
        end
      )

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "non-empty"
  end

  test "check_quotas reports openrouter available and CLI availability" do
    response =
      DynamicTool.execute(
        "check_quotas",
        %{},
        openrouter_quota_checker: fn -> {:ok, %{"limit" => 1000, "usage" => 100}} end
      )

    assert response["success"] == true
    payload = Jason.decode!(response["output"])
    assert payload["openrouter"]["available"] == true
    assert payload["openrouter"]["details"] == %{"limit" => 1000, "usage" => 100}
    assert is_boolean(payload["claude"]["available"])
    assert is_boolean(payload["gemini"]["available"])
    assert is_boolean(payload["codex"]["available"])
  end

  test "check_quotas reports openrouter unavailable on error" do
    response =
      DynamicTool.execute(
        "check_quotas",
        %{},
        openrouter_quota_checker: fn -> {:error, :missing_openrouter_api_key} end
      )

    assert response["success"] == true
    payload = Jason.decode!(response["output"])
    assert payload["openrouter"]["available"] == false
    assert payload["openrouter"]["error"] =~ "missing_openrouter_api_key"
  end

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:ok, :ok} end
      )

    assert response["success"] == true
    assert response["output"] == ":ok"
  end
end
