defmodule SymphonyElixir.OpenRouter do
  @moduledoc """
  Simple HTTP client for one-shot LLM completions via OpenRouter.
  """

  @base_url "https://openrouter.ai/api/v1"
  @default_model "anthropic/claude-3.5-sonnet"

  @spec complete(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def complete(prompt, opts \\ []) do
    model = Keyword.get(opts, :model, @default_model)

    case api_key() do
      nil ->
        {:error, :missing_openrouter_api_key}

      key ->
        body = %{
          "model" => model,
          "messages" => [%{"role" => "user", "content" => prompt}]
        }

        case Req.post("#{@base_url}/chat/completions",
               json: body,
               headers: [{"Authorization", "Bearer #{key}"}],
               connect_options: [timeout: 30_000],
               receive_timeout: 120_000
             ) do
          {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => content}} | _]}}} ->
            {:ok, content}

          {:ok, %{status: status, body: body}} ->
            {:error, {:openrouter_api_error, status, body}}

          {:error, reason} ->
            {:error, {:openrouter_request_failed, reason}}
        end
    end
  end

  @spec check_quota() :: {:ok, map()} | {:error, term()}
  def check_quota do
    case api_key() do
      nil ->
        {:error, :missing_openrouter_api_key}

      key ->
        case Req.get("#{@base_url}/auth/key",
               headers: [{"Authorization", "Bearer #{key}"}],
               connect_options: [timeout: 30_000],
               receive_timeout: 10_000
             ) do
          {:ok, %{status: 200, body: body}} when is_map(body) ->
            {:ok, body}

          {:ok, %{status: status, body: body}} ->
            {:error, {:openrouter_api_error, status, body}}

          {:error, reason} ->
            {:error, {:openrouter_request_failed, reason}}
        end
    end
  end

  defp api_key do
    System.get_env("OPENROUTER_API_KEY")
  end
end
