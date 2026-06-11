defmodule PhoenixKitProjects.Web.ProjectGanttLive do
  @moduledoc """
  Gantt / waterfall view of a project — the same data as
  `ProjectShowLive`, rendered as horizontal bars on a date axis via the
  `LiveGantt` component instead of the vertical timeline.

  Read-only: it visualizes the project's assignments as a sequential
  schedule (each task starts where the previous one ends, honoring the
  project's weekday/weekend rules via `Project.eta_from/3`) and draws
  dependency arrows between them. Mutations still happen on the vertical
  show page; the two views share the project UUID.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitProjects.Gettext
  use PhoenixKitProjects.Web.Components

  alias PhoenixKitProjects.{L10n, Paths, Projects}
  alias PhoenixKitProjects.PubSub, as: ProjectsPubSub
  alias PhoenixKitProjects.Schemas.{Assignment, Project}
  alias PhoenixKitProjects.Schemas.Task, as: TaskSchema
  alias PhoenixKitProjects.Web.Helpers, as: WebHelpers

  require Logger

  @default_wrapper_class "flex flex-col w-full px-4 py-6 gap-4"
  @valid_zooms ~w(min5 min15 hour day week month)a

  # ── Mount ───────────────────────────────────────────────────────

  @impl true
  def mount(:not_mounted_at_router, %{"id" => id} = session, socket) do
    WebHelpers.maybe_put_locale(session)
    mount(%{"id" => id}, session, socket)
  end

  def mount(%{"id" => id}, session, socket) do
    WebHelpers.maybe_put_locale(session)
    socket = WebHelpers.assign_embed_state(socket, session)

    case Projects.get_project_with_assignee(id) do
      nil ->
        {:ok,
         socket
         |> assign(default_assigns(session))
         |> put_flash(:error, gettext("Project not found."))
         |> WebHelpers.close_or_navigate(Paths.projects())}

      project ->
        if connected?(socket) do
          ProjectsPubSub.subscribe(ProjectsPubSub.topic_project(project.uuid))
          ProjectsPubSub.subscribe(ProjectsPubSub.topic_tasks())
        end

        {:ok,
         socket
         |> assign(default_assigns(session))
         |> assign(
           page_title: Project.localized_name(project, L10n.current_content_lang()),
           project: project,
           is_template: project.is_template
         )
         |> load_gantt()}
    end
  end

  defp default_assigns(session) do
    [
      page_title: "",
      project: %Project{},
      is_template: false,
      wrapper_class: Map.get(session, "wrapper_class", @default_wrapper_class),
      # `:auto` → load_gantt picks an initial zoom that fits the project's span;
      # resolved to a concrete zoom on first load, so manual switching sticks.
      zoom: :auto,
      events: [],
      connectors: [],
      expanded: MapSet.new(),
      date_range: Date.range(Date.utc_today(), Date.add(Date.utc_today(), 7)),
      today: Date.utc_today()
    ]
  end

  # ── PubSub reactivity (read-only — just reload) ──────────────────

  @impl true
  def handle_info({:projects, event, _payload}, socket)
      when event in [
             :assignment_created,
             :assignment_updated,
             :assignment_deleted,
             :dependency_added,
             :dependency_removed,
             :task_updated,
             :task_deleted,
             :project_updated,
             :project_completed,
             :project_reopened,
             :project_started
           ] do
    case Projects.get_project_with_assignee(socket.assigns.project.uuid) do
      nil -> {:noreply, socket}
      project -> {:noreply, socket |> assign(project: project) |> load_gantt()}
    end
  end

  def handle_info({:projects, :project_deleted, _payload}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, gettext("This project was deleted."))
     |> WebHelpers.close_or_navigate(Paths.projects())}
  end

  def handle_info(msg, socket) do
    Logger.debug("[ProjectGanttLive] unexpected handle_info: #{inspect(msg)}")
    {:noreply, socket}
  end

  # ── Events ──────────────────────────────────────────────────────

  @impl true
  def handle_event("set_zoom", %{"zoom" => zoom}, socket) do
    case parse_zoom(zoom) do
      nil ->
        # Unknown preset → ignore. (The schedule is zoom-independent — real
        # durations — so a display recompute is all a valid one ever needs.)
        {:noreply, socket}

      z ->
        {:noreply, socket |> assign(zoom: z) |> reflow_display()}
    end
  end

  # Toggle a sub-project's expand state (the LiveGantt chevron fires this).
  # Events already carry every descendant (tagged with parent_id); LiveGantt
  # shows/hides them from `expanded`, so no reload/requery is needed here.
  def handle_event("toggle_subproject", %{"event-id" => uuid}, socket) do
    {:noreply, update(socket, :expanded, &LiveGantt.toggle_expanded(&1, uuid))}
  end

  # Popover "Edit" action on a task bar → the assignment edit form. The owning
  # project uuid rides along as `phx-value-project` (a child task belongs to a
  # sub-project). Emit-mode-aware via `navigate_or_open/2`.
  def handle_event("gantt_edit", %{"event-id" => uuid, "project" => project_uuid}, socket) do
    {:noreply,
     WebHelpers.navigate_or_open(socket,
       to: Paths.edit_assignment(project_uuid, uuid),
       open:
         {PhoenixKitProjects.Web.AssignmentFormLive,
          %{"live_action" => "edit", "project_id" => project_uuid, "id" => uuid}}
     )}
  end

  # Popover "Open" action on a sub-project bar → drill into the child project.
  def handle_event("gantt_open", %{"child" => child_uuid}, socket) do
    {:noreply,
     WebHelpers.navigate_or_open(socket,
       to: Paths.project(child_uuid),
       open: {PhoenixKitProjects.Web.ProjectShowLive, %{"id" => child_uuid}}
     )}
  end

  # ── Data loading ────────────────────────────────────────────────

  defp load_gantt(socket) do
    project = socket.assigns.project
    deps = Projects.list_all_dependencies(project.uuid)
    lang = L10n.current_content_lang()

    {events, connectors} = build_gantt(project, deps, lang)

    socket
    |> assign(events: events, connectors: connectors)
    |> reflow_display()
  end

  # Display-only recompute from the already-built events: resolve the zoom,
  # the visible window, and the marker. The SCHEDULE itself is zoom-independent
  # (real durations), so changing zoom never rebuilds events — it only changes
  # column density, the range buffer, and the marker precision.
  defp reflow_display(socket) do
    events = socket.assigns.events
    zoom = resolve_zoom(socket.assigns.zoom, events)

    assign(socket,
      # Store the resolved concrete zoom so the switcher highlights it and later
      # reloads don't re-auto-pick over the user's choice.
      zoom: zoom,
      date_range: compute_range(events, zoom),
      # At a sub-day zoom, a precise "now" gives an exact marker + current-slot
      # column highlight; coarser zooms only need the date.
      today: if(sub_day_zoom?(zoom), do: DateTime.utc_now(), else: Date.utc_today())
    )
  end

  # Picks an initial zoom that fits the project's real span; an explicit zoom
  # passes through. A few-hour project opens at hour, a few-week one at day, etc.
  defp resolve_zoom(:auto, events) do
    case span_days(events) do
      nil -> :week
      n when n <= 2 -> :hour
      n when n <= 31 -> :day
      n when n <= 365 -> :week
      _ -> :month
    end
  end

  defp resolve_zoom(zoom, _events), do: zoom

  defp sub_day_zoom?(zoom), do: zoom in [:hour, :min15, :min5]

  defp span_days([]), do: nil

  defp span_days(events) do
    dates =
      Enum.flat_map(events, fn e ->
        [as_date(e.start), as_date(LiveGantt.Task.effective_end(e))]
      end)

    Date.diff(Enum.max(dates, Date), Enum.min(dates, Date))
  end

  # Maps the project's assignments — and every sub-project's descendants — onto
  # `LiveGantt.Task` structs, ALWAYS at the real (hour-precise) schedule so the
  # layout is identical at every display zoom — a 2-hour task is a 2-hour bar,
  # not padded out to a whole day. The display zoom only changes column density,
  # so tasks pack the same in day, week, or hour view. The durations→dates
  # layout (sequential waterfall, sub-project span) is delegated to
  # `LiveGantt.Layout.sequential/2`; we supply each task's weekday/weekend
  # calendar via `:advance`. Dependencies become finish-to-start connectors.
  defp build_gantt(project, deps, lang) do
    items = collect_items(project, nil, 0)

    layout =
      LiveGantt.Layout.sequential(items,
        start: DateTime.to_naive(schedule_anchor(project)),
        id: & &1.uuid,
        parent_id: & &1.parent_uuid,
        order: & &1.position,
        duration: fn it -> assignment_hours(it.assignment, it.project) end,
        advance: &advance_through_calendar/3,
        # No artificial minimum — reflect the real schedule. A task spans exactly
        # its duration; a zero-duration task collapses to a milestone (diamond),
        # the standard Gantt convention. LiveGantt still floors the rendered bar
        # at a few px so a short task stays visible/clickable.
        min_span: {:second, 0}
      )

    events =
      Enum.map(items, fn it ->
        %{start: s, end: e} = Map.fetch!(layout, it.uuid)
        build_task(it, s, e, lang)
      end)

    connectors = Enum.map(deps, fn d -> %{from: d.depends_on_uuid, to: d.assignment_uuid} end)
    {events, connectors}
  end

  # Flattens the project tree into layout items, each carrying its owning project
  # (for the per-project calendar) and its linking-assignment parent (nil at top
  # level). Sub-project descendants ALWAYS appear so LiveGantt can draw the
  # chevron and hide/show them via `expanded`. `@max_subproject_depth` guards
  # against pathological/corrupt nesting.
  @max_subproject_depth 32
  defp collect_items(project, parent_uuid, depth) do
    project.uuid
    |> Projects.list_assignments()
    |> Enum.flat_map(fn a ->
      item = %{
        uuid: a.uuid,
        assignment: a,
        project: project,
        parent_uuid: parent_uuid,
        position: a.position
      }

      children =
        if subproject_with_children?(a, depth),
          do: collect_items(a.child_project, a.uuid, depth + 1),
          else: []

      [item | children]
    end)
  end

  defp subproject_with_children?(%Assignment{} = a, depth) do
    Assignment.subproject?(a) and not is_nil(a.child_project) and depth < @max_subproject_depth
  end

  # `LiveGantt.Layout` `:advance` callback — move `cursor` forward by `hours`
  # honoring the assignment's effective weekday/weekend rule. The cursor is a
  # `Date` (day zoom) or `NaiveDateTime` (hour zoom); the result keeps that type
  # so Layout/LiveGantt position it at the right resolution. Layout enforces the
  # minimum span, so a 0-hour task still occupies one slot.
  defp advance_through_calendar(cursor, hours, %{assignment: a, project: project}) do
    cal_project = %{project | counts_weekends: task_counts_weekends?(a, project)}

    case Project.eta_from(cal_project, to_utc_dt(cursor), hours) do
      %DateTime{} = ended -> from_utc_dt(ended, cursor)
      _ -> cursor
    end
  end

  defp to_utc_dt(%Date{} = d), do: DateTime.new!(d, ~T[00:00:00], "Etc/UTC")
  defp to_utc_dt(%NaiveDateTime{} = t), do: DateTime.from_naive!(t, "Etc/UTC")

  defp from_utc_dt(dt, %Date{}), do: DateTime.to_date(dt)
  defp from_utc_dt(dt, %NaiveDateTime{}), do: DateTime.to_naive(dt)

  defp build_task(it, start_date, end_date, lang) do
    a = it.assignment

    extra =
      %{actions: task_actions(a, it.project.uuid)}
      |> then(&if(it.parent_uuid, do: Map.put(&1, :parent_id, it.parent_uuid), else: &1))

    %LiveGantt.Task{
      id: a.uuid,
      title: Assignment.label(a, lang) || gettext("(untitled task)"),
      start: start_date,
      end: end_date,
      progress_pct: a.progress_pct,
      color: gantt_color(a.status),
      assignee: assignee_label(a),
      extra: extra
    }
  end

  # Popover action buttons per bar. A sub-project gets "Open" (drill into the
  # child project); LiveGantt adds the expand/collapse toggle itself. A leaf
  # task gets "Edit" (its assignment form). The owning project uuid rides along
  # so the handler can build the nested edit path for child tasks.
  defp task_actions(%Assignment{} = a, project_uuid) do
    if Assignment.subproject?(a) do
      [
        %{
          id: "open",
          icon: "hero-arrow-top-right-on-square",
          tooltip: gettext("Open sub-project"),
          phx_click: "gantt_open",
          phx_value: %{"child" => a.child_project_uuid}
        }
      ]
    else
      [
        %{
          id: "edit",
          icon: "hero-pencil",
          tooltip: gettext("Edit"),
          phx_click: "gantt_edit",
          phx_value: %{"project" => project_uuid}
        }
      ]
    end
  end

  # ── Schedule helpers ────────────────────────────────────────────

  # Anchor for the sequential walk: the real start when running, the planned
  # start when scheduled, else "now" so an unstarted project still previews.
  defp schedule_anchor(%Project{started_at: %DateTime{} = at}), do: at
  defp schedule_anchor(%Project{scheduled_start_date: %DateTime{} = at}), do: at
  defp schedule_anchor(_), do: DateTime.utc_now()

  defp assignment_hours(a, project) do
    weekends? = task_counts_weekends?(a, project)

    if a.estimated_duration && a.estimated_duration_unit do
      TaskSchema.to_hours(a.estimated_duration, a.estimated_duration_unit, weekends?)
    else
      task = a.task

      TaskSchema.to_hours(
        task && task.estimated_duration,
        task && task.estimated_duration_unit,
        weekends?
      )
    end
  end

  defp task_counts_weekends?(a, project) do
    case a.counts_weekends do
      nil -> project.counts_weekends
      val -> val
    end
  end

  # ── Display helpers ─────────────────────────────────────────────

  defp gantt_color("done"), do: "bg-success"
  defp gantt_color("in_progress"), do: "bg-warning"
  defp gantt_color(_), do: "bg-primary"

  defp assignee_label(a) do
    cond do
      a.assigned_person && a.assigned_person.user -> a.assigned_person.user.email
      a.assigned_team -> a.assigned_team.name
      a.assigned_department -> a.assigned_department.name
      true -> nil
    end
  end

  # Fit the visible window to the TASKS (small padding either side), NOT to
  # today — otherwise a project whose work is weeks away from today stretches
  # the chart across the empty gap just to keep the today marker on screen.
  # When today falls outside this window, LiveGantt shows an off-screen
  # directional "Today" hint at the edge instead of widening the axis.
  defp compute_range([], _zoom) do
    today = Date.utc_today()
    Date.range(Date.add(today, -1), Date.add(today, 7))
  end

  defp compute_range(events, zoom) do
    # Events may be date- or datetime-precise; the window is always whole days,
    # so collapse every endpoint to its date.
    dates =
      Enum.flat_map(events, fn e ->
        [as_date(e.start), as_date(LiveGantt.Task.effective_end(e))]
      end)

    # One empty day of buffer on the left (a task ends on its exclusive `end`
    # date, so the right already shows one empty day — no `last` padding). At a
    # sub-day zoom a whole day is many empty columns, so drop the left buffer
    # there and let the first task's empty leading hours be the breathing room.
    left_buffer = if sub_day_zoom?(zoom), do: 0, else: 1

    first = dates |> Enum.min(Date) |> Date.add(-left_buffer)
    last = Enum.max(dates, Date)

    Date.range(first, last)
  end

  defp as_date(%Date{} = d), do: d
  defp as_date(%NaiveDateTime{} = t), do: NaiveDateTime.to_date(t)
  defp as_date(%DateTime{} = t), do: DateTime.to_date(t)

  defp parse_zoom(zoom) do
    z = String.to_existing_atom(zoom)
    if z in @valid_zooms, do: z, else: nil
  rescue
    ArgumentError -> nil
  end

  # ── Render ──────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class={@wrapper_class}>
      <div class="flex flex-wrap items-center justify-between gap-2">
        <div class="flex flex-col gap-1 min-w-0">
          <.smart_link
            navigate={if @is_template, do: Paths.template(@project.uuid), else: Paths.project(@project.uuid)}
            emit={{PhoenixKitProjects.Web.ProjectShowLive, %{"id" => @project.uuid}}}
            embed_mode={@embed_mode}
            class="link link-hover text-sm"
          >
            <.icon name="hero-arrow-left" class="w-4 h-4 inline" /> {gettext("Back to project")}
          </.smart_link>
          <h1 class="text-2xl font-bold break-words">
            {Project.localized_name(@project, L10n.current_content_lang())}
            <span class="text-base-content/50 font-normal text-lg">· {gettext("Timeline")}</span>
          </h1>
        </div>
      </div>

      <%= if @events == [] do %>
        <.empty_state
          icon="hero-chart-bar-square"
          title={gettext("No tasks to chart yet.")}
        >
          <:cta>
            <.smart_link
              navigate={Paths.new_assignment(@project.uuid)}
              emit={{PhoenixKitProjects.Web.AssignmentFormLive, %{"live_action" => "new", "project_id" => @project.uuid}}}
              embed_mode={@embed_mode}
              class="link link-primary text-sm"
            >
              {gettext("Add a task")}
            </.smart_link>
          </:cta>
        </.empty_state>
      <% else %>
        <div class="border border-base-200 rounded-lg overflow-hidden">
          <LiveGantt.gantt
            id={"project-gantt-#{@project.uuid}"}
            events={@events}
            connectors={@connectors}
            date_range={@date_range}
            zoom={@zoom}
            today={@today}
            expanded={@expanded}
            on_toggle_expand="toggle_subproject"
            on_zoom_change="set_zoom"
            zooms={[:min5, :min15, :hour, :day, :week, :month]}
            show_header={true}
            show_navigation={false}
            enable_hooks={true}
            class="max-h-[70vh]"
          />
        </div>
      <% end %>
    </div>
    """
  end
end
