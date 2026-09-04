defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000
  @max_live_log_events 300
  @agent_message_summary_prefixes ["agent message streaming", "agent message content streaming"]
  @history_stream_delta_paths [
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

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:history, load_history())
      |> assign(:history_run, nil)
      |> assign(:page, :dashboard)
      |> assign(:run_id, nil)
      |> assign(:now, DateTime.utc_now())

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"run_id" => run_id}, _uri, socket) do
    {:noreply,
     socket
     |> assign(:page, :history)
     |> assign(:run_id, run_id)
     |> assign(:history_run, load_history_run(run_id))}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, :page, :dashboard)}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()

    socket = assign(socket, :now, DateTime.utc_now())

    socket =
      case socket.assigns.page do
        :history -> reload_active_history_run(socket)
        _ -> assign(socket, :history, load_history())
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    if socket.assigns.page == :history do
      {:noreply, assign(socket, :now, DateTime.utc_now())}
    else
      {:noreply,
       socket
       |> assign(:payload, load_payload())
       |> assign(:now, DateTime.utc_now())}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              Symphony Observability
            </p>
            <h1 class="hero-title">
              <%= if @page == :history, do: "Codex Run History", else: "Operations Dashboard" %>
            </h1>
            <p class="hero-copy">
              <%= if @page == :history do %>
                Complete Codex protocol output and execution summary for this run.
              <% else %>
                Current state, retry pressure, token usage, and orchestration health for the active Symphony runtime.
              <% end %>
            </p>
          </div>

          <div class="status-stack">
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              Live
            </span>
            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              Offline
            </span>
          </div>
        </div>
      </header>

      <%= if @page == :history do %>
        <.history_detail run={@history_run} />
      <% else %>
      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            Snapshot unavailable
          </h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Running</p>
            <p class="metric-value numeric"><%= @payload.counts.running %></p>
            <p class="metric-detail">Active issue sessions in the current runtime.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Retrying</p>
            <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
            <p class="metric-detail">Issues waiting for the next retry window.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Blocked</p>
            <p class="metric-value numeric"><%= @payload.counts.blocked %></p>
            <p class="metric-detail">Issues paused for operator input or approval.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Total tokens</p>
            <p class="metric-value numeric"><%= format_int(@payload.codex_totals.total_tokens) %></p>
            <p class="metric-detail numeric">
              In <%= format_int(@payload.codex_totals.input_tokens) %> / Out <%= format_int(@payload.codex_totals.output_tokens) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Runtime</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
            <p class="metric-detail">Total Codex runtime across completed and active sessions.</p>
          </article>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Codex run history</h2>
              <p class="section-copy">Completed, failed, blocked, and cancelled execution attempts.</p>
            </div>
          </div>

          <%= if @history.runs == [] do %>
            <p class="empty-state">No completed Codex runs.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Result</th>
                    <th>Attempt</th>
                    <th>Started</th>
                    <th>Duration</th>
                    <th>Tokens</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={run <- @history.runs}>
                    <td>
                      <div class="issue-stack">
                        <.issue_identifier identifier={run.issue_identifier} url={run.issue_url} />
                        <a class="issue-link" href={"/history/#{run.run_id}"}>View log</a>
                      </div>
                    </td>
                    <td><span class={state_badge_class(run.status)}><%= run.status %></span></td>
                    <td class="numeric"><%= run.attempt || "n/a" %></td>
                    <td class="mono"><%= run.started_at || "n/a" %></td>
                    <td class="numeric"><%= format_history_duration(run.duration_seconds) %></td>
                    <td>
                      <div class="token-stack numeric">
                        <span>Total: <%= format_int(run.tokens.total_tokens) %></span>
                        <span class="muted">In <%= format_int(run.tokens.input_tokens) %> / Out <%= format_int(run.tokens.output_tokens) %></span>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Rate limits</h2>
              <p class="section-copy">Latest upstream rate-limit snapshot, when available.</p>
            </div>
          </div>

          <pre class="code-panel"><%= pretty_value(@payload.rate_limits) %></pre>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Running sessions</h2>
              <p class="section-copy">Active issues, last known agent activity, and token usage.</p>
            </div>
          </div>

          <%= if @payload.running == [] do %>
            <p class="empty-state">No active sessions.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-running">
                <colgroup>
                  <col style="width: 12rem;" />
                  <col style="width: 8rem;" />
                  <col style="width: 7.5rem;" />
                  <col style="width: 8.5rem;" />
                  <col />
                  <col style="width: 10rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Session</th>
                    <th>Runtime / turns</th>
                    <th>Codex update</th>
                    <th>Tokens</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.running}>
                    <td>
                      <div class="issue-stack">
                        <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                        <%= if entry[:run_id] do %>
                          <a class="issue-link" href={"/history/#{entry[:run_id]}"}>Live Codex log</a>
                        <% end %>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.state)}>
                        <%= entry.state %>
                      </span>
                    </td>
                    <td>
                      <div class="session-stack">
                        <%= if entry.session_id do %>
                          <button
                            type="button"
                            class="subtle-button"
                            data-label="Copy ID"
                            data-copy={entry.session_id}
                            onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                          >
                            Copy ID
                          </button>
                        <% else %>
                          <span class="muted">n/a</span>
                        <% end %>
                      </div>
                    </td>
                    <td class="numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></td>
                    <td>
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.last_message || to_string(entry.last_event || "n/a")}
                        ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                        <span class="muted event-meta">
                          <%= entry.last_event || "n/a" %>
                          <%= if entry.last_event_at do %>
                            · <span class="mono numeric"><%= entry.last_event_at %></span>
                          <% end %>
                        </span>
                      </div>
                    </td>
                    <td>
                      <div class="token-stack numeric">
                        <span>Total: <%= format_int(entry.tokens.total_tokens) %></span>
                        <span class="muted">In <%= format_int(entry.tokens.input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %></span>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Blocked sessions</h2>
              <p class="section-copy">Issues paused because Codex requested operator input or approval.</p>
            </div>
          </div>

          <%= if @payload.blocked == [] do %>
            <p class="empty-state">No blocked sessions.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 760px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Session</th>
                    <th>Blocked at</th>
                    <th>Last update</th>
                    <th>Error</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.blocked}>
                    <td>
                      <div class="issue-stack">
                        <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                        <%= if entry[:run_id] do %>
                          <a class="issue-link" href={"/history/#{entry[:run_id]}"}>View Codex log</a>
                        <% end %>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.state || "Blocked")}>
                        <%= entry.state || "Blocked" %>
                      </span>
                    </td>
                    <td>
                      <%= if entry.session_id do %>
                        <button
                          type="button"
                          class="subtle-button"
                          data-label="Copy ID"
                          data-copy={entry.session_id}
                          onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                        >
                          Copy ID
                        </button>
                      <% else %>
                        <span class="muted">n/a</span>
                      <% end %>
                    </td>
                    <td class="mono"><%= entry.blocked_at || "n/a" %></td>
                    <td>
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.last_message || to_string(entry.last_event || "n/a")}
                        ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                        <span class="muted event-meta">
                          <%= entry.last_event || "n/a" %>
                          <%= if entry.last_event_at do %>
                            · <span class="mono numeric"><%= entry.last_event_at %></span>
                          <% end %>
                        </span>
                      </div>
                    </td>
                    <td><%= entry.error || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Retry queue</h2>
              <p class="section-copy">Issues waiting for the next retry window.</p>
            </div>
          </div>

          <%= if @payload.retrying == [] do %>
            <p class="empty-state">No issues are currently backing off.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 680px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Attempt</th>
                    <th>Due at</th>
                    <th>Error</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.retrying}>
                    <td>
                      <div class="issue-stack">
                        <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td><%= entry.attempt %></td>
                    <td class="mono"><%= entry.due_at || "n/a" %></td>
                    <td><%= entry.error || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>
      <% end %>
      <% end %>
    </section>
    """
  end

  attr(:run, :map, required: true)

  defp history_detail(assigns) do
    ~H"""
    <%= if @run[:error] do %>
      <section class="error-card">
        <h2 class="error-title">Run unavailable</h2>
        <p class="error-copy"><strong><%= @run.error.code %>:</strong> <%= @run.error.message %></p>
        <p><a class="issue-link" href="/">Back to dashboard</a></p>
      </section>
    <% else %>
      <section class="section-card">
        <div class="section-header">
          <div>
            <p class="eyebrow"><%= @run.issue_identifier || "Unknown issue" %></p>
            <h2 class="section-title"><%= @run.status || "running" %> · attempt <%= @run.attempt || "n/a" %></h2>
            <p class="section-copy mono"><%= @run.run_id %></p>
          </div>
          <a class="issue-link" href="/">Back to dashboard</a>
        </div>

        <div class="history-summary">
          <span>Started <strong><%= @run.started_at || "n/a" %></strong></span>
          <span>Finished <strong><%= @run.finished_at || "running" %></strong></span>
          <span>Duration <strong><%= format_history_duration(@run.duration_seconds) %></strong></span>
          <span>Tokens <strong><%= format_int(@run.tokens.total_tokens) %></strong></span>
        </div>
      </section>

      <% events = visible_history_events(@run) %>
      <% log_entries = @run.events |> history_log_entries() |> visible_history_log_entries(@run) %>
      <% live_window? = length(events) < length(@run.events) %>

      <section class="section-card codex-log-card">
        <div class="section-header">
          <div>
            <h2 class="section-title">Codex output</h2>
            <p class="section-copy">Readable execution output. The log stays in this panel while the run is active.</p>
          </div>
          <span class={history_status_class(@run.status)}><%= @run.status || "running" %></span>
        </div>

        <%= if live_window? do %>
          <p class="log-window-note">
            Showing the latest <%= max_live_log_events() %> events while live. The complete log is retained in history.
          </p>
        <% end %>

        <%= if events == [] do %>
          <p class="empty-state">No Codex events recorded yet.</p>
        <% else %>
          <div class="codex-terminal" id="codex-terminal">
            <div class="codex-terminal-bar">
              <span class="terminal-lights" aria-hidden="true"><i></i><i></i><i></i></span>
              <span class="codex-terminal-title">codex app-server</span>
              <span class="codex-terminal-mode">human-readable</span>
            </div>

            <ol id="codex-log" class="codex-log-stream" aria-label="Codex execution log">
              <li
                :for={{event, index} <- Enum.with_index(log_entries)}
                id={"codex-log-event-#{index}"}
                class={["codex-log-line", history_event_class(event.event)]}
              >
                <time class="codex-log-time mono" datetime={event.at || ""}>
                  <%= format_history_time(event.at) %>
                </time>
                <span class="codex-log-marker" aria-hidden="true"></span>
                <div class="codex-log-content">
                  <span class="codex-log-kind"><%= history_event_label(event.event) %></span>
                  <p class="codex-log-text"><%= history_event_text(event) %></p>
                </div>
              </li>
            </ol>
          </div>
        <% end %>

        <details class="history-debug">
          <summary>Raw JSONL (debug)</summary>
          <div class="history-debug-list">
            <article :for={{event, index} <- Enum.with_index(events)} class="history-debug-event">
              <div class="history-debug-header">
                <span><%= index + 1 %>. <%= history_event_label(event.event) %></span>
                <span class="muted mono"><%= format_history_time(event.at) %></span>
              </div>
              <pre class="code-panel"><%= event.raw || "n/a" %></pre>
            </article>
          </div>
        </details>
      </section>
    <% end %>
    """
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp load_history do
    Presenter.history_payload()
  end

  defp load_history_run(run_id) do
    case Presenter.history_run_payload(run_id) do
      {:ok, run} -> run
      {:error, :run_not_found} -> %{error: %{code: "run_not_found", message: "Run not found"}}
    end
  end

  defp reload_history_run(%{assigns: %{page: :history, run_id: run_id}} = socket) do
    assign(socket, :history_run, load_history_run(run_id))
  end

  defp reload_history_run(socket), do: socket

  defp reload_active_history_run(%{assigns: %{history_run: %{finished_at: finished_at}}} = socket)
       when is_binary(finished_at),
       do: socket

  defp reload_active_history_run(socket), do: reload_history_run(socket)

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  attr(:identifier, :string, required: true)
  attr(:url, :string, default: nil)

  defp issue_identifier(assigns) do
    assigns = assign(assigns, :href, external_issue_url(assigns.url))

    ~H"""
    <%= if @href do %>
      <a
        class="issue-id issue-id-link"
        href={@href}
        target="_blank"
        rel="noopener noreferrer"
        aria-label={"Open #{@identifier} in the issue tracker"}
      ><%= @identifier %></a>
    <% else %>
      <span class="issue-id"><%= @identifier %></span>
    <% end %>
    """
  end

  defp external_issue_url(url) when is_binary(url) do
    url = String.trim(url)

    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        url

      _ ->
        nil
    end
  end

  defp external_issue_url(_url), do: nil

  defp completed_runtime_seconds(payload) do
    payload.codex_totals.seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp format_history_duration(seconds) when is_number(seconds), do: format_runtime_seconds(seconds)
  defp format_history_duration(_seconds), do: "n/a"

  defp visible_history_events(%{events: events, finished_at: nil}) do
    Enum.take(events, -@max_live_log_events)
  end

  defp visible_history_events(%{events: events}), do: events

  defp max_live_log_events, do: @max_live_log_events

  defp visible_history_log_entries(entries, %{finished_at: nil}),
    do: Enum.take(entries, -@max_live_log_events)

  defp visible_history_log_entries(entries, _run), do: entries

  defp history_log_entries(events) do
    events
    |> Enum.reduce([], &append_history_log_entry/2)
    |> Enum.reverse()
  end

  defp append_history_log_entry(event, entries) do
    if agent_message_streaming?(event) do
      append_agent_message_entry(event, entries)
    else
      [event | entries]
    end
  end

  defp append_agent_message_entry(event, [%{event: :agent_message} = entry | rest]) do
    [merge_agent_message(entry, event) | rest]
  end

  defp append_agent_message_entry(event, entries), do: [new_agent_message_entry(event) | entries]

  defp new_agent_message_entry(event) do
    delta = history_stream_delta(event)

    %{
      at: Map.get(event, :at),
      event: :agent_message,
      summary: "agent message",
      display: normalize_history_stream_text(delta)
    }
  end

  defp merge_agent_message(entry, event) do
    delta = history_stream_delta(event) || ""
    display = merge_history_stream_text(Map.get(entry, :display), delta)

    entry
    |> Map.put(:at, Map.get(event, :at) || Map.get(entry, :at))
    |> Map.put(:display, display)
  end

  defp agent_message_streaming?(event) do
    stream_text = Map.get(event, :stream_text) || Map.get(event, "stream_text")

    if is_binary(stream_text) do
      true
    else
      summary = Map.get(event, :summary) || Map.get(event, "summary") || ""
      normalized = String.downcase(summary)

      Enum.any?(@agent_message_summary_prefixes, &String.starts_with?(normalized, &1))
    end
  end

  defp history_stream_delta(event) do
    case Map.get(event, :stream_text) || Map.get(event, "stream_text") do
      text when is_binary(text) -> text
      _ -> raw_history_stream_delta(event) || summary_history_stream_delta(event)
    end
  end

  defp raw_history_stream_delta(event) do
    with raw when is_binary(raw) <- Map.get(event, :raw) || Map.get(event, "raw"),
         {:ok, payload} <- Jason.decode(raw),
         text when is_binary(text) <- Enum.find_value(@history_stream_delta_paths, &history_json_path(payload, &1)) do
      text
    else
      _ -> nil
    end
  end

  defp summary_history_stream_delta(event) do
    summary = Map.get(event, :summary) || Map.get(event, "summary") || ""

    Enum.find_value(@agent_message_summary_prefixes, fn prefix ->
      prefix = prefix <> ": "
      if String.starts_with?(summary, prefix), do: String.replace_prefix(summary, prefix, "")
    end)
  end

  defp history_json_path(value, []), do: value

  defp history_json_path(value, [key | rest]) when is_map(value),
    do: history_json_path(Map.get(value, key), rest)

  defp history_json_path(_value, _path), do: nil

  defp merge_history_stream_text(nil, ""), do: nil
  defp merge_history_stream_text(nil, delta), do: normalize_history_stream_text(delta)

  defp merge_history_stream_text(existing, delta),
    do: normalize_history_stream_text(existing <> delta)

  defp normalize_history_stream_text(nil), do: nil

  defp normalize_history_stream_text(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> String.replace(~r/\n{3,}/, "\n\n")
  end

  defp history_status_class(status) do
    normalized = status |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["failed", "error", "blocked", "cancelled"]) ->
        "codex-terminal-status codex-terminal-status-danger"

      String.contains?(normalized, ["completed", "success"]) ->
        "codex-terminal-status codex-terminal-status-success"

      true ->
        "codex-terminal-status codex-terminal-status-live"
    end
  end

  defp history_event_class(event) do
    normalized = history_event_label(event) |> String.downcase()

    cond do
      String.contains?(normalized, ["failed", "error", "blocked", "cancelled", "malformed"]) ->
        "codex-log-line-danger"

      String.contains?(normalized, ["started", "completed", "success"]) ->
        "codex-log-line-success"

      true ->
        "codex-log-line-neutral"
    end
  end

  defp history_event_label(event) when is_atom(event), do: event |> Atom.to_string() |> format_event_label()
  defp history_event_label(event) when is_binary(event), do: format_event_label(event)
  defp history_event_label(_event), do: "event"

  defp format_event_label(event) do
    event
    |> String.replace("_", " ")
    |> String.replace("/", " · ")
  end

  defp history_event_text(event) do
    display = Map.get(event, :display) || Map.get(event, "display")

    if is_binary(display) and display != "" do
      display
    else
      Map.get(event, :summary) || Map.get(event, "summary") || "event received"
    end
  end

  defp format_history_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> Calendar.strftime(datetime, "%H:%M:%S")
      _ -> value
    end
  end

  defp format_history_time(_value), do: "n/a"

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end
