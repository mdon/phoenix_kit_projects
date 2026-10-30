defmodule PhoenixKitProjects.Web.Components.AssigneePicker do
  @moduledoc """
  The one assignee picker of the module: whose a task, a sub-project, a
  project or a library task's default is. One search over people, teams,
  departments and accounts without a staff record (core `<.search_picker>`),
  "Assign to me", the choice as a chip with its faces, and "Recent" chips —
  the viewer's own picks first, so one removed again stays a press away
  (`PhoenixKitProjects.Assignees.recent_for_viewer/4`).

  Lifted out of the task form (the boss, 2026-10-30: "the user assignment
  thing being different in basically every pop-up"). It is a component plus
  the events behind it; the LiveView keeps only what is its own — where the
  choice goes.

  ## In a LiveView

      # mount (and whenever the record changes):
      socket |> AssigneePicker.init(project, source: "project_form")
             |> AssigneePicker.refresh_chip({kind, uuid} | nil)

      # every picker event, in one clause:
      def handle_event(event, params, socket) when event in AssigneePicker.events(),
        do: AssigneePicker.handle_event(event, params, socket, __MODULE__)

      # the two callbacks it calls back:
      def picker_allowed?(socket), do: …            # may this viewer assign, now?
      def picker_choose(socket, kind, uuid), do: …  # put it in the form (nil = nobody)

      # in the form:
      <.assignee_picker id="x-assignee" fields={…} chip={@assignee_chip} … />
      # after the form (a form inside a form is not HTML):
      <.assignee_picker_outside search_form="x-assignee-form" staff_confirm={@staff_confirm} />

  Assigns it keeps: `assignee_chip`, `recent_assignees`, `my_person_uuid`,
  `can_assign?`, `staff_confirm`, `assignee_notice`, `assignee_project_uuid`.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitProjects.Gettext

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Modal, only: [confirm_modal: 1]
  import PhoenixKitWeb.Components.Core.SearchPicker, only: [search_picker: 1]
  import PhoenixKitProjects.Web.Components.AssigneeFaces, only: [assignee_faces: 1]

  alias Phoenix.LiveView
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitProjects.{Activity, Assignees, L10n, People}

  @events ~w(assignee_search assignee_pick assignee_recent assign_to_me
             staff_create_confirm staff_create_cancel assignee_noop assignee_clear)

  @doc "The events the picker sends; a LiveView hands each to `handle_event/4`."
  @spec events() :: [String.t()]
  def events, do: @events

  @callback picker_allowed?(LiveView.Socket.t()) :: boolean()
  @callback picker_choose(LiveView.Socket.t(), String.t() | nil, String.t() | nil) ::
              LiveView.Socket.t()

  # ── State ──────────────────────────────────────────────────────────

  @doc """
  The picker's assigns for a project (nil: no project, e.g. the task
  library): the viewer's staff person, the Recent chips and whether they may
  assign (`opts[:can_assign?]`, default true). `opts[:source]` names the
  form in the log line of a staff record made from it.
  """
  @spec init(LiveView.Socket.t(), map() | nil, keyword()) :: LiveView.Socket.t()
  def init(socket, project, opts \\ []) do
    project_uuid =
      case project do
        %{uuid: uuid} when is_binary(uuid) and uuid != "" -> uuid
        _ -> nil
      end

    socket
    |> Phoenix.Component.assign(
      assignee_project_uuid: project_uuid,
      assignee_source: Keyword.get(opts, :source, "task_form"),
      my_person_uuid: my_person_uuid(socket),
      can_assign?: Keyword.get(opts, :can_assign?, true)
    )
    |> refresh_recent()
    |> Phoenix.Component.assign_new(:staff_confirm, fn -> nil end)
    |> Phoenix.Component.assign_new(:assignee_notice, fn -> nil end)
    |> Phoenix.Component.assign_new(:assignee_chip, fn -> %{key: nil, row: nil} end)
  end

  @doc "Re-reads the Recent chips (after a pick, they lead with it)."
  @spec refresh_recent(LiveView.Socket.t()) :: LiveView.Socket.t()
  def refresh_recent(socket) do
    recent =
      Assignees.recent_for_viewer(
        Activity.actor_uuid(socket),
        socket.assigns[:assignee_project_uuid],
        8,
        L10n.current_content_lang()
      )

    Phoenix.Component.assign(socket, :recent_assignees, recent)
  end

  @doc """
  The chip of the chosen assignee (`{kind, uuid}` or nil): its row and
  faces, looked up only when the choice changed.
  """
  @spec refresh_chip(LiveView.Socket.t(), {String.t(), String.t()} | nil) :: LiveView.Socket.t()
  def refresh_chip(socket, key) do
    case socket.assigns[:assignee_chip] do
      %{key: ^key, row: row} when not is_nil(row) or is_nil(key) ->
        socket

      _ ->
        row =
          case key do
            {kind, uuid} -> Assignees.describe(kind, uuid, L10n.current_content_lang())
            nil -> nil
          end

        Phoenix.Component.assign(socket, :assignee_chip, %{key: key, row: row})
    end
  end

  @doc """
  `{kind, uuid}` of the assignee three uuid fields hold — the first set of
  person, team, department — or nil. `get` reads one field (`:person` …).
  """
  @spec key_of((atom() -> term())) :: {String.t(), String.t()} | nil
  def key_of(get) when is_function(get, 1) do
    Enum.find_value([person: "person", team: "team", department: "department"], fn {f, kind} ->
      case get.(f) do
        uuid when is_binary(uuid) and uuid != "" -> {kind, uuid}
        _ -> nil
      end
    end)
  end

  @doc """
  The three assignee fields for one choice, under the names `names` gives
  (`%{person: "assigned_person_uuid", …}`): exactly one set.
  """
  @spec field_attrs(map(), String.t() | nil, String.t() | nil) :: map()
  def field_attrs(names, kind, uuid) do
    Map.new([person: "person", team: "team", department: "department"], fn {f, k} ->
      {Map.fetch!(names, f), if(k == kind, do: uuid)}
    end)
  end

  # ── Events ─────────────────────────────────────────────────────────

  @doc """
  One picker event. `mod` is the LiveView: its `picker_allowed?/1` is asked
  before anything is chosen, and `picker_choose/3` puts the choice in its
  form. A pick names a row the search offered and is looked up again, so a
  forged kind or uuid assigns nobody.
  """
  @spec handle_event(String.t(), map(), LiveView.Socket.t(), module()) ::
          {:noreply, LiveView.Socket.t()}
  def handle_event("assignee_search", %{"q" => q} = params, socket, _mod) when is_binary(q) do
    limit =
      case Integer.parse(to_string(params["limit"] || "")) do
        {n, _} when n > 0 -> n
        _ -> 20
      end

    {rows, more?} = Assignees.search_assignees(q, limit, L10n.current_content_lang())
    rows = Enum.map(rows, &Map.take(&1, [:kind, :uuid, :label, :sublabel, :icon]))

    {:noreply,
     LiveView.push_event(socket, "assignee_results", %{q: q, results: rows, has_more: more?})}
  end

  def handle_event("assignee_search", _params, socket, _mod), do: {:noreply, socket}

  # A user with no staff person yet: assigning them makes one, so it asks
  # first (`staff_confirm`).
  def handle_event("assignee_pick", %{"kind" => "user", "uuid" => uuid}, socket, mod) do
    {:noreply,
     socket |> assign_user(uuid, :other, mod) |> LiveView.push_event("assignee_staged", %{})}
  end

  def handle_event("assignee_pick", %{"kind" => kind, "uuid" => uuid}, socket, mod) do
    socket =
      case Assignees.describe(kind, uuid) do
        %{kind: kind, uuid: uuid} -> choose(socket, kind, uuid, mod)
        nil -> socket
      end

    {:noreply, LiveView.push_event(socket, "assignee_staged", %{})}
  end

  def handle_event("assignee_recent", %{"kind" => kind, "uuid" => uuid}, socket, mod) do
    offered? =
      Enum.any?(socket.assigns[:recent_assignees] || [], &(&1.kind == kind and &1.uuid == uuid))

    {:noreply, if(offered?, do: choose(socket, kind, uuid, mod), else: socket)}
  end

  # The viewer themself — their staff person, made (after asking) when their
  # account has none.
  def handle_event("assign_to_me", _params, socket, mod) do
    case Activity.actor_uuid(socket) do
      uuid when is_binary(uuid) -> {:noreply, assign_user(socket, uuid, :self, mod)}
      _ -> {:noreply, socket}
    end
  end

  # "Create and assign": the question holds the user, re-checked here.
  def handle_event("staff_create_confirm", _params, socket, mod) do
    case socket.assigns[:staff_confirm] do
      %{user_uuid: user_uuid, who: who} ->
        socket = Phoenix.Component.assign(socket, :staff_confirm, nil)

        if mod.picker_allowed?(socket),
          do: {:noreply, create_and_assign(socket, user_uuid, who, mod)},
          else: {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("staff_create_cancel", _params, socket, _mod),
    do: {:noreply, Phoenix.Component.assign(socket, :staff_confirm, nil)}

  # The search box's own form: Enter there must submit nothing.
  def handle_event("assignee_noop", _params, socket, _mod), do: {:noreply, socket}

  def handle_event("assignee_clear", _params, socket, mod) do
    if mod.picker_allowed?(socket),
      do:
        {:noreply,
         socket |> Phoenix.Component.assign(:assignee_notice, nil) |> mod.picker_choose(nil, nil)},
      else: {:noreply, socket}
  end

  def handle_event(_event, _params, socket, _mod), do: {:noreply, socket}

  # A choice the viewer made: put in the form, and remembered as theirs
  # for the Recent chips.
  defp choose(socket, kind, uuid, mod) do
    if mod.picker_allowed?(socket) do
      Assignees.remember_pick(Activity.actor_uuid(socket), kind, uuid)

      socket
      |> Phoenix.Component.assign(:assignee_notice, nil)
      |> mod.picker_choose(kind, uuid)
      |> refresh_recent()
    else
      socket
    end
  end

  # Assigns a user through their staff person: straight away when they
  # have one; asking first when assigning would create it; refused, with a
  # line saying where to restore it, when it is trashed. `who` is `:self`
  # (Assign to me) or `:other` (a picked user, looked up again).
  defp assign_user(socket, user_uuid, who, mod) do
    if mod.picker_allowed?(socket) do
      case People.get_person_by_user_uuid(user_uuid) do
        %{status: "trashed"} ->
          Phoenix.Component.assign(socket, :assignee_notice, {:trashed, who})

        %{uuid: person_uuid} ->
          choose(socket, "person", person_uuid, mod)

        nil ->
          ask_staff_create(socket, user_uuid, who)
      end
    else
      socket
    end
  end

  defp ask_staff_create(socket, user_uuid, who) do
    name =
      case who do
        :self -> self_name(socket, user_uuid)
        :other -> with %{label: label} <- Assignees.describe_user(user_uuid), do: label
      end

    if is_binary(name),
      do:
        Phoenix.Component.assign(socket, :staff_confirm, %{
          user_uuid: user_uuid,
          who: who,
          name: name
        }),
      else: socket
  end

  defp self_name(socket, user_uuid) do
    case Activity.actor_uuid(socket) == user_uuid && Auth.get_user(user_uuid) do
      %User{} = user -> if People.assignable_user?(user), do: People.new_person_name(user)
      _ -> nil
    end
  end

  defp create_and_assign(socket, user_uuid, who, mod) do
    case People.ensure_person_for_user(user_uuid,
           actor_uuid: Activity.actor_uuid(socket),
           source: socket.assigns[:assignee_source] || "task_form"
         ) do
      {:ok, %{uuid: person_uuid}} ->
        socket
        |> then(
          &if(who == :self,
            do: Phoenix.Component.assign(&1, :my_person_uuid, person_uuid),
            else: &1
          )
        )
        |> choose("person", person_uuid, mod)

      {:error, :trashed_person} ->
        Phoenix.Component.assign(socket, :assignee_notice, {:trashed, who})

      {:error, _} ->
        LiveView.put_flash(socket, :error, gettext("Could not create the staff record."))
    end
  end

  # The viewer's own staff person — what "Assign to me" assigns — or nil
  # (nil also when it is trashed: then there is no one to assign as them).
  defp my_person_uuid(socket) do
    with uuid when is_binary(uuid) <- Activity.actor_uuid(socket),
         %{uuid: person_uuid, status: status} when status != "trashed" <-
           People.get_person_by_user_uuid(uuid) do
      person_uuid
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # ── The component ──────────────────────────────────────────────────

  @doc """
  The picker, inside the form it fills. `fields` are the hidden inputs that
  carry the choice (`[{name, value}]`, the record's three assignee fields);
  `search_form` is the id of the empty form that owns the search box
  (`assignee_picker_outside/1`), so Enter there never submits the form.
  """
  attr(:id, :string, required: true)
  attr(:label, :string, default: nil)
  attr(:fields, :list, default: [])
  attr(:chip, :map, required: true)
  attr(:can_assign?, :boolean, default: true)
  attr(:my_person_uuid, :string, default: nil)
  attr(:recent, :list, default: [])
  attr(:notice, :any, default: nil)
  attr(:search_form, :string, required: true)
  attr(:me_id, :string, default: nil)
  attr(:class, :any, default: nil)

  def assignee_picker(assigns) do
    assigns =
      assign(assigns,
        recent_shown: Enum.reject(assigns.recent, &({&1.kind, &1.uuid} == assigns.chip.key)),
        me_id: assigns.me_id || "#{assigns.id}-me",
        kind: kind_of(assigns.chip)
      )

    ~H"""
    <div id={@id} class={["flex flex-col gap-2", @class]} data-kind={@kind}>
      <input type="hidden" name="assign_type" value={@kind} />
      <input :for={{name, value} <- @fields} type="hidden" name={name} value={value} />
      <div class="flex items-center justify-between gap-2">
        <label :if={@label} for={"#{@id}-search"} class="text-sm font-semibold">{@label}</label>
        <%!-- Works for any account: one with no staff person gets one
             made, after the form asks (`staff_confirm`). --%>
        <button
          :if={@can_assign? and @chip.key != {"person", @my_person_uuid}}
          type="button"
          id={@me_id}
          phx-click="assign_to_me"
          class="btn btn-xs btn-outline gap-1 ml-auto"
        >
          <.icon name="hero-user-plus" class="w-3.5 h-3.5" /> {gettext("Assign to me")}
        </button>
      </div>
      <p :if={@can_assign? and match?({:trashed, _}, @notice)} id={"#{@id}-notice"} class="text-xs text-warning">
        <%= if @notice == {:trashed, :self} do %>
          {gettext("Your staff record is in the trash; restore it under Staff → People to be assigned.")}
        <% else %>
          {gettext("Their staff record is in the trash; restore it under Staff → People to assign them.")}
        <% end %>
      </p>

      <div
        :if={@chip.key}
        id={"#{@id}-chosen"}
        data-kind={@kind}
        class="flex items-center gap-2 rounded-box border border-base-300 px-2.5 py-1.5"
      >
        <%= if @chip.row && @chip.row[:faces] do %>
          <.assignee_faces faces={@chip.row.faces} size="sm" />
        <% else %>
          <span class="inline-flex items-center justify-center w-8 h-8 rounded-full bg-base-200 shrink-0">
            <.icon name={(@chip.row && @chip.row.icon) || "hero-user"} class="w-4 h-4 text-base-content/60" />
          </span>
        <% end %>
        <div class="min-w-0 flex-1">
          <div class="truncate font-medium text-sm">
            {(@chip.row && @chip.row.label) || gettext("No longer listed")}
          </div>
          <div :if={@chip.row && @chip.row.sublabel} class="truncate text-xs text-base-content/60">
            {@chip.row.sublabel}
          </div>
        </div>
        <button
          :if={@can_assign?}
          type="button"
          id={"#{@id}-clear"}
          phx-click="assignee_clear"
          class="btn btn-ghost btn-xs btn-circle"
          aria-label={gettext("Remove the assignee")}
          title={gettext("Remove the assignee")}
        >
          <.icon name="hero-x-mark" class="w-4 h-4" />
        </button>
      </div>
      <p :if={is_nil(@chip.key) and not @can_assign?} class="text-sm text-base-content/60">
        {gettext("Unassigned")}
      </p>

      <.search_picker
        :if={@can_assign?}
        id={"#{@id}-search"}
        dropdown_id={"#{@id}-list"}
        form={@search_form}
        search_event="assignee_search"
        results_event="assignee_results"
        pick_event="assignee_pick"
        staged_event="assignee_staged"
        search_on_focus
        close_on_pick
        row_layout="stacked"
        placeholder={
          if @chip.key,
            do: gettext("Hand it to someone else — search a person, team or department"),
            else: gettext("Search a person, team or department")
        }
        class="input input-sm w-full"
        searching_label={gettext("Searching…")}
        more_label={gettext("Load more")}
        loading_more_label={gettext("Loading…")}
        no_matches_label={gettext("No matches")}
      />

      <div :if={@can_assign? and @recent_shown != []} id={"#{@id}-recent"} class="flex flex-wrap items-center gap-1.5">
        <span class="text-xs text-base-content/60">{gettext("Recent:")}</span>
        <button
          :for={r <- @recent_shown}
          type="button"
          phx-click="assignee_recent"
          phx-value-kind={r.kind}
          phx-value-uuid={r.uuid}
          class="btn btn-xs btn-ghost border-base-300 gap-1 font-normal"
          title={r.sublabel || r.label}
        >
          <.icon name={r.icon} class="w-3.5 h-3.5 opacity-60" />{r.label}
        </button>
      </div>
    </div>
    """
  end

  @doc """
  What the picker needs outside the form it sits in: the empty form that
  owns its search box, and the "Create a staff record?" question.
  """
  attr(:search_form, :string, required: true)
  attr(:staff_confirm, :any, default: nil)

  def assignee_picker_outside(assigns) do
    ~H"""
    <form id={@search_form} phx-submit="assignee_noop" class="hidden"></form>
    <%!-- In the drawer this dialog sits inside the drawer's own dialog,
         and daisyUI's `modal-end` makes every modal box under it full
         height (a descendant rule); a confirm keeps its own height. --%>
    <style :if={@staff_confirm}>
      #pk-modal-staff_create_cancel > .modal-box { height: auto; }
    </style>
    <.confirm_modal
      :if={@staff_confirm}
      show={true}
      on_confirm="staff_create_confirm"
      on_cancel="staff_create_cancel"
      title={gettext("Create a staff record?")}
      title_icon="hero-user-plus"
      messages={[
        {:info,
         gettext(
           "%{name} has no staff record yet. Assigning creates one (Staff → People) with their name and account; you can fill it in or remove it there later.",
           name: @staff_confirm.name
         )}
      ]}
      prompt=""
      cancel_text={gettext("Cancel")}
      confirm_text={gettext("Create and assign")}
    />
    """
  end

  defp kind_of(%{key: {kind, _uuid}}), do: kind
  defp kind_of(_chip), do: ""
end
