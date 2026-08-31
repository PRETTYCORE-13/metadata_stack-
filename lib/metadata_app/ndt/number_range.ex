defmodule MetadataApp.NDT.NumberRange do
  use Ecto.Schema
  import Ecto.Changeset

  # Contador vivo de un (perfil, período) — ver moduledoc de
  # MetadataApp.NDT.Numbering. Es la fila que NDT.Numbering.next/1
  # bloquea con SELECT ... FOR UPDATE; nunca se edita a mano fuera de ahí.
  # El perfil (`pty_ndt_configuracion`, 2026-08-31) es un BC real del
  # motor de catálogos, no un schema hecho a mano -- ver moduledoc de
  # MetadataApp.NDT.Numbering para el porqué del cambio.
  schema "ndt_number_ranges" do
    belongs_to :perfil, MetadataApp.MetaBusinessProcess.Catalogos.PtyNdtConfiguracion, foreign_key: :pty_ndt_configuracion_id
    field :periodo, :string, default: ""
    field :numero_actual, :integer, default: 0

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(range, attrs) do
    range
    |> cast(attrs, [:pty_ndt_configuracion_id, :periodo, :numero_actual])
    # `:periodo` queda AFUERA de validate_required a propósito -- ""
    # (política "nunca", ver moduledoc de NDT.Numbering) es un valor
    # legítimo, y validate_required/2 trata cualquier string vacío como
    # "en blanco" sin importar `trim:` (bug real encontrado acá: rechazaba
    # el sentinel "" como si el campo faltara).
    |> validate_required([:pty_ndt_configuracion_id, :numero_actual])
    |> validate_number(:numero_actual, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:pty_ndt_configuracion_id)
    |> unique_constraint([:pty_ndt_configuracion_id, :periodo], name: :ndt_number_ranges_perfil_periodo_unico_index)
  end
end
