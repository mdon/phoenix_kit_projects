defmodule PhoenixKitProjects.Assignees do
  @moduledoc """
  The single resolver for "whose work is this?" questions against the
  polymorphic assignment assignee (person OR team OR department).

  A person's **effective scope** is themselves plus one level of inherited
  membership: the teams they belong to (staff `TeamMembership`) and the
  departments those teams sit in plus their own primary department. One level
  only, by design — transitive roll-ups (team of team, parent departments)
  don't exist in the staff model and would be guesswork here.

  `match/2` answers whether an assignment falls in a scope and HOW — `:direct`
  or `{:team, name}` / `{:department, name}` — so UIs can show provenance
  ("via Engineering") instead of implying personal ownership. Consumers pick
  their semantics: inherited = any match; direct-only = `:direct` matches.

  Built for the Overview calendar's assignee filter, but deliberately
  UI-agnostic: any future per-person surface (widgets, queues, a staff-side
  consumer via an events contract) should resolve through this module rather
  than re-deriving membership joins — the panel-review risk was exactly this
  logic drifting between call sites.

  Staff reads are rescued to safe defaults (same convention as
  `Projects.list_assignments_for_user/1`) — an assignee filter must never
  crash the dashboard.
  """

  alias PhoenixKitProjects.Schemas.Assignment
  alias PhoenixKitStaff.Schemas.{Department, Person, Team}
  alias PhoenixKitStaff.Staff

  require Logger

  @typedoc """
  A resolved person scope: the person plus their one-level memberships, with
  display names captured for provenance labels.
  """
  @type scope :: %{
          person_uuid: String.t(),
          person_name: String.t(),
          team_names: %{optional(String.t()) => String.t()},
          department_names: %{optional(String.t()) => String.t()}
        }

  @doc """
  Builds the effective scope for a staff person: their uuid, their teams
  (via memberships), and their departments (the teams' departments + their
  primary department). Names are localized to `lang` for provenance labels.

  Returns `nil` when the person doesn't exist (or the staff read fails).
  """
  @spec scope_for_person(String.t(), String.t() | nil) :: scope() | nil
  def scope_for_person(person_uuid, lang \\ nil) when is_binary(person_uuid) do
    case Staff.get_person(person_uuid, preload: [:user, :primary_department]) do
      nil -> nil
      person -> build_scope(person, lang)
    end
  rescue
    e in [Postgrex.Error, DBConnection.ConnectionError, Ecto.QueryError] ->
      Logger.warning(
        "[Assignees] staff lookup failed for #{person_uuid}: #{Exception.message(e)}"
      )

      nil
  end

  @doc """
  The scope for the CURRENT USER (auth uuid → staff person), or `nil` when
  they have no staff person. Backs the filter's "Me" shortcut.
  """
  @spec scope_for_user(String.t() | nil, String.t() | nil) :: scope() | nil
  def scope_for_user(nil, _lang), do: nil

  def scope_for_user(user_uuid, lang) when is_binary(user_uuid) do
    case Staff.get_person_by_user_uuid(user_uuid, preload: []) do
      nil -> nil
      person -> scope_for_person(person.uuid, lang)
    end
  rescue
    e in [Postgrex.Error, DBConnection.ConnectionError, Ecto.QueryError] ->
      Logger.warning(
        "[Assignees] staff lookup failed for user #{user_uuid}: #{Exception.message(e)}"
      )

      nil
  end

  @doc """
  How `assignment` falls inside `scope`:

    * `:direct` — assigned to the person themselves
    * `{:team, name}` — assigned to a team the person belongs to
    * `{:department, name}` — assigned to a department in the person's scope
    * `nil` — outside the scope

  Direct-only consumers accept only `:direct`; inherited consumers accept any
  non-nil result (and can show the tuple's name as provenance).
  """
  @spec match(Assignment.t(), scope()) ::
          :direct | {:team, String.t()} | {:department, String.t()} | nil
  def match(%Assignment{} = a, scope) do
    cond do
      a.assigned_person_uuid && a.assigned_person_uuid == scope.person_uuid ->
        :direct

      a.assigned_team_uuid && Map.has_key?(scope.team_names, a.assigned_team_uuid) ->
        {:team, Map.fetch!(scope.team_names, a.assigned_team_uuid)}

      a.assigned_department_uuid &&
          Map.has_key?(scope.department_names, a.assigned_department_uuid) ->
        {:department, Map.fetch!(scope.department_names, a.assigned_department_uuid)}

      true ->
        nil
    end
  end

  @doc "Whether the assignment has no assignee at all (person/team/department)."
  @spec unassigned?(Assignment.t()) :: boolean()
  def unassigned?(%Assignment{} = a) do
    is_nil(a.assigned_person_uuid) and is_nil(a.assigned_team_uuid) and
      is_nil(a.assigned_department_uuid)
  end

  @doc """
  People options for an assignee picker: `{display_name, uuid}` sorted by
  name. Trashed people are excluded by the staff context. Empty on a failed
  staff read.
  """
  @spec people_options() :: [{String.t(), String.t()}]
  def people_options do
    Staff.list_people(preload: [:user])
    |> Enum.map(&{Person.display_name(&1), &1.uuid})
    |> Enum.sort_by(fn {name, _} -> String.downcase(name) end)
  rescue
    e in [Postgrex.Error, DBConnection.ConnectionError, Ecto.QueryError] ->
      Logger.warning("[Assignees] people listing failed: #{Exception.message(e)}")
      []
  end

  defp build_scope(person, lang) do
    memberships =
      try do
        Staff.list_memberships_for_person(person.uuid)
      rescue
        e in [Postgrex.Error, DBConnection.ConnectionError, Ecto.QueryError] ->
          Logger.warning(
            "[Assignees] memberships lookup failed for #{person.uuid}: #{Exception.message(e)}"
          )

          []
      end

    teams = memberships |> Enum.map(& &1.team) |> Enum.reject(&is_nil/1)

    team_names =
      Map.new(teams, fn t -> {t.uuid, Team.localized_name(t, lang)} end)

    departments =
      teams
      |> Enum.map(& &1.department)
      |> Enum.reject(&is_nil/1)
      |> then(fn deps ->
        case person.primary_department do
          %{} = d -> [d | deps]
          _ -> deps
        end
      end)

    department_names =
      Map.new(departments, fn d ->
        {d.uuid, Department.localized_name(d, lang)}
      end)

    %{
      person_uuid: person.uuid,
      person_name: Person.display_name(person),
      team_names: team_names,
      department_names: department_names
    }
  end
end
