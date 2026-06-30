defmodule MetadataApp.Repo do
  use Ecto.Repo,
    otp_app: :metadata_app,
    adapter: Ecto.Adapters.Postgres
end
