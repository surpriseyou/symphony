defmodule SymphonyElixir.CodexHistory do
  @moduledoc """
  Small JSONL-backed history store for Codex runs.

  The GenServer serializes writes so a run's events stay ordered without adding a
  database or a second persistence dependency.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{LogFile, StatusDashboard}

  @default_max_bytes 10 * 1024 * 1024
  @default_max_files 5
  @default_limit 100
  @agent_message_methods [
    "item/agentMessage/delta",
    "codex/event/agent_message_delta",
    "codex/event/agent_message_content_delta"
  ]
  @agent_message_text_paths [
    ["params", "delta"],
    ["params", "textDelta"],
    ["params", "msg", "delta"],
    ["params", "msg", "textDelta"],
    ["params", "msg", "content"],
    ["params", "msg", "payload", "delta"],
    ["params", "msg", "payload", "textDelta"],
    ["params", "msg", "payload", "content"],
    ["params", "msg", "payload", "text"]
  ]

  @type run :: %{
          required(:run_id) => String.t(),
          optional(atom()) => term()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec new_run_id() :: String.t()
  def new_run_id do
    "run-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"
  end

  @spec start_run(run()) :: :ok
  def start_run(run), do: start_run(run, __MODULE__)

  @spec start_run(run(), GenServer.server()) :: :ok
  def start_run(%{run_id: run_id} = run, server) when is_binary(run_id) do
    write(server, {:start_run, run})
  end

  def start_run(_run, _server), do: :ok

  @spec record_event(run(), map()) :: :ok
  def record_event(run, update), do: record_event(run, update, __MODULE__)

  @spec record_event(run(), map(), GenServer.server()) :: :ok
  def record_event(%{run_id: run_id} = run, update, server) when is_binary(run_id) and is_map(update) do
    write(server, {:record_event, run, update})
  end

  def record_event(_run, _update, _server), do: :ok

  @spec finish_run(run(), atom() | String.t()) :: :ok
  def finish_run(run, status), do: finish_run(run, status, nil, __MODULE__)

  @spec finish_run(run(), atom() | String.t(), term()) :: :ok
  def finish_run(run, status, reason), do: finish_run(run, status, reason, __MODULE__)

  @spec finish_run(run(), atom() | String.t(), term(), GenServer.server()) :: :ok
  def finish_run(%{run_id: run_id} = run, status, reason, server) when is_binary(run_id) do
    write(server, {:finish_run, run, status, reason})
  end

  def finish_run(_run, _status, _reason, _server), do: :ok

  @spec list(keyword()) :: [map()]
  def list(opts \\ []) when is_list(opts) do
    server = Keyword.get(opts, :server, __MODULE__)
    limit = normalize_limit(Keyword.get(opts, :limit, @default_limit))
    issue_identifier = Keyword.get(opts, :issue_identifier)

    case call(server, {:list, limit, issue_identifier}) do
      {:ok, runs} -> runs
      _ -> []
    end
  end

  @spec get(String.t(), GenServer.server()) :: {:ok, map()} | :not_found
  def get(run_id, server \\ __MODULE__) when is_binary(run_id) do
    case call(server, {:get, run_id}) do
      {:ok, run} -> {:ok, run}
      _ -> :not_found
    end
  end

  @impl true
  def init(opts) do
    log_file = Application.get_env(:symphony_elixir, :log_file, LogFile.default_log_file())

    {:ok,
     %{
       path:
         Keyword.get(
           opts,
           :path,
           Application.get_env(
             :symphony_elixir,
             :codex_history_file,
             Path.join(Path.dirname(log_file), "codex-history.jsonl")
           )
         ),
       max_bytes: Keyword.get(opts, :max_bytes, @default_max_bytes),
       max_files: max(1, Keyword.get(opts, :max_files, @default_max_files))
     }}
  end

  @impl true
  def handle_call({:list, limit, issue_identifier}, _from, state) do
    runs = state |> read_runs() |> filter_issue(issue_identifier) |> Enum.filter(&finished?/1)
    {:reply, {:ok, runs |> Enum.take(limit) |> Enum.map(&Map.delete(&1, :events))}, state}
  end

  def handle_call({:get, run_id}, _from, state) do
    result =
      state
      |> read_runs()
      |> Enum.find(:not_found, &(&1.run_id == run_id))
      |> add_active_duration()

    {:reply, result_to_get(result), state}
  end

  @impl true
  def handle_cast({:start_run, run}, state) do
    append_start_record(state, run)
    {:noreply, state}
  end

  def handle_cast({:record_event, run, update}, state) do
    append_event_record(state, run, update)
    {:noreply, state}
  end

  def handle_cast({:finish_run, run, status, reason}, state) do
    append_finish_record(state, run, status, reason)
    {:noreply, state}
  end

  defp write(server, message) do
    case Process.whereis(server) do
      pid when is_pid(pid) ->
        GenServer.cast(pid, message)

      _ ->
        :ok
    end
  end

  defp call(server, message) do
    case Process.whereis(server) do
      pid when is_pid(pid) ->
        try do
          GenServer.call(pid, message, 15_000)
        catch
          :exit, _ -> :unavailable
        end

      _ ->
        :unavailable
    end
  end

  defp append_record(state, record) do
    with {:ok, line} <- Jason.encode(record),
         :ok <- File.mkdir_p(Path.dirname(state.path)),
         :ok <- rotate_if_needed(state),
         :ok <- File.write(state.path, line <> "\n", [:append, :binary]) do
      :ok
    else
      {:error, reason} ->
        Logger.error("Unable to persist Codex history at #{state.path}: #{inspect(reason)}")
        :ok
    end
  end

  defp append_start_record(state, run) do
    append_record(state, %{
      "type" => "run_started",
      "run_id" => run_value(run, :run_id),
      "issue_id" => run_value(run, :issue_id),
      "issue_identifier" => run_value(run, :issue_identifier),
      "issue_url" => run_value(run, :issue_url),
      "attempt" => run_value(run, :attempt),
      "worker_host" => run_value(run, :worker_host),
      "workspace_path" => run_value(run, :workspace_path),
      "session_id" => run_value(run, :session_id),
      "started_at" => iso8601(run_value(run, :started_at)) || now_iso8601()
    })
  end

  defp append_event_record(state, run, update) do
    append_record(state, %{
      "type" => "event",
      "run_id" => run_value(run, :run_id),
      "at" => iso8601(Map.get(update, :timestamp)) || now_iso8601(),
      "event" => string_value(Map.get(update, :event)),
      "summary" => StatusDashboard.humanize_codex_message(update),
      "stream_text" => stream_text(update),
      "raw" => raw_value(update),
      "session_id" => run_value(run, :session_id),
      "worker_host" => run_value(run, :worker_host),
      "workspace_path" => run_value(run, :workspace_path),
      "tokens" => token_record(run)
    })
  end

  defp append_finish_record(state, run, status, reason) do
    append_record(state, %{
      "type" => "run_finished",
      "run_id" => run_value(run, :run_id),
      "issue_id" => run_value(run, :issue_id),
      "issue_identifier" => run_value(run, :issue_identifier),
      "issue_url" => run_value(run, :issue_url),
      "attempt" => run_value(run, :attempt),
      "started_at" => iso8601(run_value(run, :started_at)),
      "finished_at" => now_iso8601(),
      "status" => string_value(status),
      "error" => reason_value(reason),
      "duration_seconds" => duration_seconds(run_value(run, :started_at)),
      "session_id" => run_value(run, :session_id),
      "worker_host" => run_value(run, :worker_host),
      "workspace_path" => run_value(run, :workspace_path),
      "tokens" => token_record(run)
    })
  end

  defp rotate_if_needed(%{path: path, max_bytes: max_bytes, max_files: max_files}) do
    case File.stat(path) do
      {:ok, %{size: size}} when size > 0 and size >= max_bytes ->
        rotate_history_files(path, max_files)

      {:ok, _stat} ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp rotate_history_files(path, max_files) when max_files > 1 do
    File.rm(rotated_path(path, max_files - 1))

    if max_files > 2 do
      Enum.each(Range.new(max_files - 2, 1, -1), &rename_rotated_file(path, &1))
    end

    File.rename(path, rotated_path(path, 1))
  end

  defp rotate_history_files(path, _max_files), do: File.rm(path)

  defp rename_rotated_file(path, index) do
    old_path = rotated_path(path, index)
    new_path = rotated_path(path, index + 1)
    if File.exists?(old_path), do: File.rename(old_path, new_path)
  end

  defp read_runs(state) do
    state
    |> history_paths()
    |> Enum.flat_map(&read_records/1)
    |> aggregate_runs()
    |> Enum.sort_by(&started_sort_key/1, :desc)
  end

  defp history_paths(%{path: path, max_files: max_files}) do
    rotated =
      if max_files > 1 do
        Enum.map(Range.new(1, max_files - 1, 1), &rotated_path(path, &1)) |> Enum.reverse()
      else
        []
      end

    rotated ++ [path]
  end

  defp read_records(path) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&decode_record/1)

      {:error, _reason} ->
        []
    end
  end

  defp decode_record(line) do
    case Jason.decode(line) do
      {:ok, record} when is_map(record) -> [record]
      _ -> []
    end
  end

  defp aggregate_runs(records) do
    records
    |> Enum.reduce(%{}, fn
      %{"type" => "run_started", "run_id" => run_id} = record, runs ->
        Map.update(runs, run_id, new_run(record), &merge_run(&1, record))

      %{"type" => "event", "run_id" => run_id} = record, runs ->
        Map.update(runs, run_id, new_run(record), &merge_event(&1, record))

      %{"type" => "run_finished", "run_id" => run_id} = record, runs ->
        Map.update(runs, run_id, new_run(record), &merge_finished(&1, record))

      _record, runs ->
        runs
    end)
    |> Map.values()
  end

  defp new_run(record) do
    %{
      run_id: record["run_id"],
      issue_id: record["issue_id"],
      issue_identifier: record["issue_identifier"],
      issue_url: record["issue_url"],
      attempt: record["attempt"],
      worker_host: record["worker_host"],
      workspace_path: record["workspace_path"],
      session_id: record["session_id"],
      started_at: record["started_at"],
      finished_at: nil,
      status: nil,
      error: nil,
      duration_seconds: nil,
      tokens: empty_tokens(),
      events: []
    }
  end

  defp merge_run(run, record) do
    Map.merge(run, Map.take(new_run(record), [:issue_id, :issue_identifier, :issue_url, :attempt, :worker_host, :workspace_path, :session_id, :started_at]), fn _key, old, new -> new || old end)
  end

  defp merge_event(run, record) do
    run
    |> merge_run(record)
    |> Map.put(:tokens, normalize_tokens(record["tokens"]))
    |> Map.update!(:events, &(&1 ++ [event_from_record(record)]))
  end

  defp merge_finished(run, record) do
    run
    |> merge_run(record)
    |> Map.merge(%{
      finished_at: record["finished_at"],
      status: record["status"],
      error: record["error"],
      duration_seconds: record["duration_seconds"],
      tokens: normalize_tokens(record["tokens"])
    })
  end

  defp event_from_record(record) do
    %{
      at: record["at"],
      event: record["event"],
      summary: record["summary"],
      stream_text: record["stream_text"],
      raw: record["raw"]
    }
  end

  defp filter_issue(runs, nil), do: runs
  defp filter_issue(runs, issue_identifier), do: Enum.filter(runs, &(&1.issue_identifier == issue_identifier))

  defp finished?(run), do: is_binary(run.finished_at)

  defp result_to_get(:not_found), do: :not_found
  defp result_to_get(run), do: {:ok, run}

  defp add_active_duration(:not_found), do: :not_found

  defp add_active_duration(%{duration_seconds: nil, started_at: started_at} = run) do
    Map.put(run, :duration_seconds, duration_seconds_from_string(started_at))
  end

  defp add_active_duration(run), do: run

  defp started_sort_key(%{started_at: started_at}) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime, :microsecond)
      _ -> 0
    end
  end

  defp started_sort_key(_run), do: 0

  defp rotated_path(path, index), do: "#{path}.#{index}"

  defp run_value(run, key) when is_map(run), do: Map.get(run, key)
  defp run_value(_run, _key), do: nil

  defp string_value(value) when is_binary(value), do: value
  defp string_value(value) when is_atom(value), do: Atom.to_string(value)
  defp string_value(value) when is_integer(value), do: Integer.to_string(value)
  defp string_value(_value), do: nil

  defp stream_text(update) do
    payload = Map.get(update, :payload) || Map.get(update, :message)

    case map_path_value(payload, ["method"]) do
      method when method in @agent_message_methods ->
        Enum.find_value(@agent_message_text_paths, &stream_text_value(payload, &1))

      _ ->
        nil
    end
  end

  defp stream_text_value(payload, path) do
    case map_path_value(payload, path) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp map_path_value(value, []), do: value

  defp map_path_value(value, [key | rest]) when is_map(value),
    do: value |> Map.get(key) |> map_path_value(rest)

  defp map_path_value(_value, _path), do: nil

  defp raw_value(update) do
    case Map.get(update, :raw) do
      raw when is_binary(raw) ->
        raw

      _ ->
        case Jason.encode(Map.get(update, :payload, update)) do
          {:ok, value} -> value
          _ -> inspect(Map.get(update, :payload, update), limit: :infinity)
        end
    end
  end

  defp reason_value(nil), do: nil
  defp reason_value(reason) when is_binary(reason), do: reason
  defp reason_value(reason), do: inspect(reason, limit: 40)

  defp duration_seconds(%DateTime{} = started_at), do: max(DateTime.diff(DateTime.utc_now(), started_at, :millisecond) / 1_000, 0)
  defp duration_seconds(_started_at), do: nil

  defp duration_seconds_from_string(started_at) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, datetime, _offset} -> duration_seconds(datetime)
      _ -> nil
    end
  end

  defp duration_seconds_from_string(_started_at), do: nil

  defp iso8601(%DateTime{} = datetime), do: datetime |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
  defp iso8601(_datetime), do: nil

  defp now_iso8601, do: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()

  defp integer_value(value) when is_integer(value), do: value
  defp integer_value(_value), do: 0

  defp empty_tokens, do: %{input_tokens: 0, output_tokens: 0, total_tokens: 0}

  defp token_record(run) do
    %{
      "input_tokens" => integer_value(run_value(run, :codex_input_tokens)),
      "output_tokens" => integer_value(run_value(run, :codex_output_tokens)),
      "total_tokens" => integer_value(run_value(run, :codex_total_tokens))
    }
  end

  defp normalize_tokens(tokens) when is_map(tokens) do
    %{
      input_tokens: integer_value(tokens["input_tokens"] || tokens[:input_tokens]),
      output_tokens: integer_value(tokens["output_tokens"] || tokens[:output_tokens]),
      total_tokens: integer_value(tokens["total_tokens"] || tokens[:total_tokens])
    }
  end

  defp normalize_tokens(_tokens), do: empty_tokens()

  defp normalize_limit(value) when is_integer(value), do: min(max(value, 1), @default_limit)
  defp normalize_limit(_value), do: @default_limit
end
