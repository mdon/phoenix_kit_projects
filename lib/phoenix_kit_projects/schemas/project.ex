defmodule PhoenixKitProjects.Schemas.Project do
  @moduledoc """
  A project container. Can start immediately (set up tasks first, then
  mark as started) or be scheduled for a future date.

  ## Soft-hide / archive

  `archived_at` is the soft-hide flag — null = visible, non-null =
  archived. Mirrors the workspace's `trashed_at` convention used by
  publishing posts and core files.

  The legacy `status` string column (V86 / V94) is **kept in the table
  but no longer read or written** by application code. See
  `phoenix_kit_projects/AGENTS.md` for the deprecation note.
  """

  use Ecto.Schema
  use Gettext, backend: PhoenixKitWeb.Gettext

  import Ecto.Changeset

  alias PhoenixKitProjects.Schemas.Assignment

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @start_modes ~w(immediate scheduled)

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          name: String.t() | nil,
          description: String.t() | nil,
          is_template: boolean() | nil,
          counts_weekends: boolean() | nil,
          start_mode: String.t() | nil,
          scheduled_start_date: Date.t() | nil,
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          archived_at: DateTime.t() | nil,
          assignments: [Assignment.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_projects" do
    field(:name, :string)
    field(:description, :string)
    field(:is_template, :boolean, default: false)
    field(:counts_weekends, :boolean, default: false)
    field(:start_mode, :string, default: "immediate")
    field(:scheduled_start_date, :date)
    field(:started_at, :utc_datetime)
    field(:completed_at, :utc_datetime)
    field(:archived_at, :utc_datetime)

    has_many(:assignments, Assignment, foreign_key: :project_uuid, on_delete: :delete_all)

    timestamps(type: :utc_datetime)
  end

  @required ~w(name start_mode)a
  @optional ~w(description is_template counts_weekends scheduled_start_date started_at completed_at archived_at)a

  def changeset(project, attrs) do
    project
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_inclusion(:start_mode, @start_modes)
    |> maybe_require_date()
    |> unique_constraint(:name,
      name: name_index_for(project, attrs),
      message: gettext("already taken")
    )
  end

  # V105 split the single `phoenix_kit_projects_name_index` into two
  # partial indexes — one per `is_template` value — so a template
  # named "Onboarding" and a real project named "Onboarding" can
  # coexist. Pick the index whose `WHERE` clause matches the row we're
  # about to write so Ecto attaches the constraint error to the right
  # changeset field.
  defp name_index_for(project, attrs) do
    template? =
      case Map.get(attrs, :is_template, Map.get(attrs, "is_template")) do
        nil -> Map.get(project, :is_template, false)
        # Phoenix forms send `"true"`/`"false"`. Programmatic callers
        # may pass native booleans, the legacy HTML checkbox `"on"`,
        # or `1`/`"1"`. All canonicalised here so the constraint
        # error attaches to the right field regardless of caller shape.
        v -> v in [true, "true", "1", 1, "on"]
      end

    if template?,
      do: :phoenix_kit_projects_name_template_index,
      else: :phoenix_kit_projects_name_project_index
  end

  defp maybe_require_date(changeset) do
    if get_field(changeset, :start_mode) == "scheduled" do
      validate_required(changeset, [:scheduled_start_date],
        message: gettext("required for scheduled projects")
      )
    else
      changeset
    end
  end

  def start_modes, do: @start_modes

  @typedoc """
  Human-meaningful lifecycle state derived from the persisted fields.

  Combines the `archived_at` soft-hide flag, completion timestamps,
  start mode, and the scheduled date into the label that's actually
  meaningful in the UI.
  """
  @type derived_state ::
          :archived | :template | :completed | :running | :overdue | :scheduled | :setup

  @doc """
  Lifecycle state for this project, in priority order:

    * `:archived`  — soft-hidden (`archived_at` is set)
    * `:template`  — `is_template: true`
    * `:completed` — `completed_at` is set
    * `:running`   — `started_at` is set and not yet completed
    * `:overdue`   — scheduled, the scheduled_start_date has passed, not started
    * `:scheduled` — scheduled, start date still in the future, not started
    * `:setup`     — immediate start mode, not yet started

  `today` is injected so callers can pin "now" for tests.
  """
  @spec derived_status(t(), Date.t()) :: derived_state()
  def derived_status(%__MODULE__{} = p, today \\ Date.utc_today()) do
    cond do
      p.archived_at -> :archived
      p.is_template -> :template
      p.completed_at -> :completed
      p.started_at -> :running
      scheduled_overdue?(p, today) -> :overdue
      p.start_mode == "scheduled" -> :scheduled
      true -> :setup
    end
  end

  defp scheduled_overdue?(%__MODULE__{start_mode: "scheduled", scheduled_start_date: %Date{} = d}, today),
    do: Date.compare(d, today) == :lt

  defp scheduled_overdue?(_, _), do: false
end
