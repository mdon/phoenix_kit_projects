defmodule PhoenixKitProjects.Activity do
  @moduledoc "Activity logging wrapper for the Projects module."

  require Logger

  @module "projects"

  @doc "Logs a projects activity entry via `PhoenixKit.Activity`. Swallows errors so it never crashes the caller."
  def log(action, opts) when is_binary(action) and is_list(opts) do
    if Code.ensure_loaded?(PhoenixKit.Activity) do
      PhoenixKit.Activity.log(%{
        action: action,
        module: @module,
        mode: Keyword.get(opts, :mode, "manual"),
        actor_uuid: Keyword.get(opts, :actor_uuid),
        resource_type: Keyword.get(opts, :resource_type),
        resource_uuid: Keyword.get(opts, :resource_uuid),
        target_uuid: Keyword.get(opts, :target_uuid),
        metadata: Keyword.get(opts, :metadata, %{})
      })
    else
      :activity_unavailable
    end
  rescue
    e ->
      Logger.warning("[Projects] Activity logging error: #{Exception.message(e)}")
      {:error, e}
  end

  @doc "Extracts `user.uuid` from the LiveView socket assigns."
  def actor_uuid(socket) do
    case socket.assigns[:phoenix_kit_current_user] do
      %{uuid: uuid} -> uuid
      _ -> nil
    end
  end
end
