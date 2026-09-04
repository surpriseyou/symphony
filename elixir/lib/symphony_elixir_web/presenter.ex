defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{CodexHistory, Config, Orchestrator, StatusDashboard, Workspace}

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        %{
          generated_at: generated_at,
          counts: %{
            running: length(snapshot.running),
            retrying: length(snapshot.retrying),
            blocked: length(Map.get(snapshot, :blocked, []))
          },
          running: Enum.map(snapshot.running, &running_entry_payload/1),
          retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
          blocked: Enum.map(Map.get(snapshot, :blocked, []), &blocked_entry_payload/1),
          codex_totals: snapshot.codex_totals,
          rate_limits: snapshot.rate_limits
        }

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    histories = CodexHistory.list(issue_identifier: issue_identifier, server: history_server())
    snapshot = Orchestrator.snapshot(orchestrator, snapshot_timeout_ms)

    issue_payload_from_snapshot(issue_identifier, histories, snapshot)
  end

  defp issue_payload_from_snapshot(issue_identifier, histories, %{} = snapshot) do
    running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
    retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))
    blocked = Enum.find(Map.get(snapshot, :blocked, []), &(&1.identifier == issue_identifier))

    case {running, retry, blocked} do
      {nil, nil, nil} -> historical_issue_or_not_found(issue_identifier, histories)
      _ -> {:ok, issue_payload_body(issue_identifier, running, retry, blocked, histories)}
    end
  end

  defp issue_payload_from_snapshot(issue_identifier, histories, _snapshot),
    do: historical_issue_or_not_found(issue_identifier, histories)

  defp historical_issue_or_not_found(_issue_identifier, []), do: {:error, :issue_not_found}

  defp historical_issue_or_not_found(issue_identifier, histories),
    do: {:ok, historical_issue_payload(issue_identifier, histories)}

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

  @spec history_payload(non_neg_integer()) :: map()
  def history_payload(limit \\ 100) when is_integer(limit) do
    runs = CodexHistory.list(limit: limit, server: history_server())

    %{
      generated_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      runs: Enum.map(runs, &history_summary/1),
      count: length(runs)
    }
  end

  @spec history_run_payload(String.t()) :: {:ok, map()} | {:error, :run_not_found}
  def history_run_payload(run_id) when is_binary(run_id) do
    case CodexHistory.get(run_id, history_server()) do
      {:ok, run} -> {:ok, run}
      :not_found -> {:error, :run_not_found}
    end
  end

  defp issue_payload_body(issue_identifier, running, retry, blocked, histories) do
    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry, blocked),
      status: issue_status(running, retry, blocked),
      workspace: %{
        path: workspace_path(issue_identifier, running, retry, blocked),
        host: workspace_host(running, retry, blocked)
      },
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      running: running && running_issue_payload(running),
      retry: retry && retry_issue_payload(retry),
      blocked: blocked && blocked_issue_payload(blocked),
      logs: %{
        codex_session_logs: Enum.map(histories, &history_log_payload/1)
      },
      history: Enum.map(histories, &history_summary/1),
      recent_events: recent_events_payload(running || blocked),
      last_error: (blocked && blocked.error) || (retry && retry.error),
      tracked: %{}
    }
  end

  defp historical_issue_payload(issue_identifier, [latest | _] = histories) do
    latest = full_history(latest)

    %{
      issue_identifier: issue_identifier,
      issue_id: latest.issue_id,
      status: latest.status || "completed",
      workspace: %{
        path:
          latest.workspace_path ||
            Path.join(Config.settings!().workspace.root, Workspace.workspace_key(issue_identifier)),
        host: latest.worker_host
      },
      attempts: %{
        restart_count: max(length(histories) - 1, 0),
        current_retry_attempt: 0
      },
      running: nil,
      retry: nil,
      blocked: nil,
      logs: %{codex_session_logs: Enum.map(histories, &history_log_payload/1)},
      history: Enum.map(histories, &history_summary/1),
      recent_events: latest.events,
      last_error: latest.error,
      tracked: %{}
    }
  end

  defp full_history(%{run_id: run_id} = summary) do
    case CodexHistory.get(run_id, history_server()) do
      {:ok, run} -> run
      :not_found -> Map.put(summary, :events, [])
    end
  end

  defp issue_id_from_entries(running, retry, blocked),
    do: (running && running.issue_id) || (retry && retry.issue_id) || (blocked && blocked.issue_id)

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(running, _retry, _blocked) when not is_nil(running), do: "running"
  defp issue_status(nil, retry, _blocked) when not is_nil(retry), do: "retrying"
  defp issue_status(nil, nil, _blocked), do: "blocked"

  defp running_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      issue_url: Map.get(entry, :issue_url),
      state: entry.state,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_codex_timestamp),
      tokens: %{
        input_tokens: entry.codex_input_tokens,
        output_tokens: entry.codex_output_tokens,
        total_tokens: entry.codex_total_tokens
      }
    }
    |> maybe_put_run_id(Map.get(entry, :run_id))
  end

  defp retry_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      issue_url: Map.get(entry, :issue_url),
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path)
    }
  end

  defp blocked_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      issue_url: Map.get(entry, :issue_url),
      state: entry.state,
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      blocked_at: iso8601(entry.blocked_at),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      last_event_at: iso8601(entry.last_codex_timestamp)
    }
    |> maybe_put_run_id(Map.get(entry, :run_id))
  end

  defp running_issue_payload(running) do
    %{
      worker_host: Map.get(running, :worker_host),
      workspace_path: Map.get(running, :workspace_path),
      session_id: running.session_id,
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      started_at: iso8601(running.started_at),
      last_event: running.last_codex_event,
      last_message: summarize_message(running.last_codex_message),
      last_event_at: iso8601(running.last_codex_timestamp),
      tokens: %{
        input_tokens: running.codex_input_tokens,
        output_tokens: running.codex_output_tokens,
        total_tokens: running.codex_total_tokens
      }
    }
    |> maybe_put_run_id(Map.get(running, :run_id))
  end

  defp retry_issue_payload(retry) do
    %{
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error,
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path)
    }
  end

  defp blocked_issue_payload(blocked) do
    %{
      worker_host: Map.get(blocked, :worker_host),
      workspace_path: Map.get(blocked, :workspace_path),
      session_id: blocked.session_id,
      state: blocked.state,
      error: blocked.error,
      blocked_at: iso8601(blocked.blocked_at),
      last_event: blocked.last_codex_event,
      last_message: summarize_message(blocked.last_codex_message),
      last_event_at: iso8601(blocked.last_codex_timestamp)
    }
    |> maybe_put_run_id(Map.get(blocked, :run_id))
  end

  defp workspace_path(issue_identifier, running, retry, blocked) do
    (running && Map.get(running, :workspace_path)) ||
      (retry && Map.get(retry, :workspace_path)) ||
      (blocked && Map.get(blocked, :workspace_path)) ||
      Path.join(Config.settings!().workspace.root, Workspace.workspace_key(issue_identifier))
  end

  defp workspace_host(running, retry, blocked) do
    (running && Map.get(running, :worker_host)) ||
      (retry && Map.get(retry, :worker_host)) ||
      (blocked && Map.get(blocked, :worker_host))
  end

  defp recent_events_payload(nil), do: []

  defp recent_events_payload(entry) do
    [
      %{
        at: iso8601(entry.last_codex_timestamp),
        event: entry.last_codex_event,
        message: summarize_message(entry.last_codex_message)
      }
    ]
    |> Enum.reject(&is_nil(&1.at))
  end

  defp history_summary(run), do: Map.delete(run, :events)

  defp history_log_payload(run) do
    %{
      label: run.status || run.run_id,
      run_id: run.run_id,
      url: "/api/v1/history/#{URI.encode(run.run_id)}"
    }
  end

  defp history_server do
    Application.get_env(:symphony_elixir, :codex_history_server, CodexHistory)
  end

  defp maybe_put_run_id(payload, run_id) when is_binary(run_id), do: Map.put(payload, :run_id, run_id)
  defp maybe_put_run_id(payload, _run_id), do: payload

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: StatusDashboard.humanize_codex_message(message)

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil
end
