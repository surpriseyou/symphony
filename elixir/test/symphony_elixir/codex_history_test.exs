defmodule SymphonyElixir.CodexHistoryTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.CodexHistory

  test "persists ordered events and reloads them after the writer restarts" do
    root = temp_root()
    path = Path.join(root, "codex-history.jsonl")
    name = unique_name("History")
    started_at = DateTime.add(DateTime.utc_now(), -2, :second)

    {:ok, pid} = CodexHistory.start_link(name: name, path: path)
    run = run("run-ordered", started_at)

    assert :ok = CodexHistory.start_run(run, name)
    assert :ok = CodexHistory.record_event(run, update("item/started", "first"), name)
    assert :ok = CodexHistory.record_event(run, update("item/completed", "second"), name)
    assert :ok = CodexHistory.finish_run(run, :completed, nil, name)

    assert {:ok, stored} = CodexHistory.get(run.run_id, name)
    assert stored.status == "completed"
    assert Enum.map(stored.events, & &1.raw) == ["{\"step\":1}", "{\"step\":2}"]
    assert [summary] = CodexHistory.list(server: name, limit: 1)
    assert summary.run_id == run.run_id
    refute Map.has_key?(summary, :events)

    GenServer.stop(pid)
    {:ok, _pid} = CodexHistory.start_link(name: name, path: path)

    assert {:ok, reloaded} = CodexHistory.get(run.run_id, name)
    assert length(reloaded.events) == 2

    cleanup(root, name)
  end

  test "keeps only the configured number of rotated files" do
    root = temp_root()
    path = Path.join(root, "codex-history.jsonl")
    name = unique_name("Rotation")
    {:ok, _pid} = CodexHistory.start_link(name: name, path: path, max_bytes: 300, max_files: 3)

    Enum.each(1..6, fn index ->
      run = run("run-#{index}", DateTime.utc_now())
      assert :ok = CodexHistory.start_run(run, name)
      assert :ok = CodexHistory.finish_run(run, :failed, "failure", name)
    end)

    assert is_list(CodexHistory.list(server: name))

    assert File.exists?(path)
    assert File.exists?(path <> ".1")
    assert File.exists?(path <> ".2")
    refute File.exists?(path <> ".3")

    cleanup(root, name)
  end

  test "persists agent message delta text for readable aggregation" do
    root = temp_root()
    path = Path.join(root, "codex-history.jsonl")
    name = unique_name("MessageDelta")
    {:ok, _pid} = CodexHistory.start_link(name: name, path: path)
    run = run("run-message", DateTime.utc_now())

    update = %{
      event: :notification,
      timestamp: DateTime.utc_now(),
      payload: %{
        "method" => "item/agentMessage/delta",
        "params" => %{"delta" => "hello\nworld"}
      },
      raw: "{\"method\":\"item/agentMessage/delta\",\"params\":{\"delta\":\"hello\\nworld\"}}"
    }

    assert :ok = CodexHistory.start_run(run, name)
    assert :ok = CodexHistory.record_event(run, update, name)
    assert {:ok, %{events: [event]}} = CodexHistory.get(run.run_id, name)
    assert event.stream_text == "hello\nworld"

    cleanup(root, name)
  end

  test "ignores malformed lines while reading history" do
    root = temp_root()
    path = Path.join(root, "codex-history.jsonl")
    name = unique_name("Malformed")
    File.mkdir_p!(root)
    File.write!(path, "not json\n")
    {:ok, _pid} = CodexHistory.start_link(name: name, path: path)

    assert CodexHistory.list(server: name) == []

    cleanup(root, name)
  end

  defp run(run_id, started_at) do
    %{
      run_id: run_id,
      issue_id: "issue-1",
      issue_identifier: "MT-1",
      issue_url: "https://example.org/issues/MT-1",
      attempt: 1,
      workspace_path: "/tmp/MT-1",
      started_at: started_at,
      codex_input_tokens: 10,
      codex_output_tokens: 20,
      codex_total_tokens: 30
    }
  end

  defp update(method, step) do
    %{
      event: :notification,
      timestamp: DateTime.utc_now(),
      payload: %{"method" => method, "step" => step},
      raw: if(step == "first", do: "{\"step\":1}", else: "{\"step\":2}")
    }
  end

  defp temp_root do
    root = Path.join(System.tmp_dir!(), "symphony-codex-history-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    root
  end

  defp unique_name(prefix), do: Module.concat(__MODULE__, "#{prefix}#{System.unique_integer([:positive])}")

  defp cleanup(root, name) do
    if pid = Process.whereis(name), do: GenServer.stop(pid)
    File.rm_rf!(root)
  end
end
