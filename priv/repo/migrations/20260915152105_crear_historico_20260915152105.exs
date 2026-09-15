defmodule MetadataApp.Repo.Migrations.CrearHistorico20260915152105 do
  use Ecto.Migration

  def change do
    create table(:historico) do
      add :sysudn_codigo_k, :string, size: 50, null: true
      add :empleado, :string, size: 100, null: true
      add :preventa, :string, size: 50, null: true
      add :liquid_referencia, :string, size: 50, null: true
      add :liquid_fechaent, :date, null: true
      add :facdoc_referencia, :string, size: 50, null: true
      add :pedcte_referencia, :string, size: 50, null: true
      add :vtarut_codigo_k, :string, size: 50, null: true
      add :systts_codigo_k, :string, size: 50, null: true
      add :cred, :string, size: 100, null: true
      add :ctecli_fechaalta, :date, null: true
      add :ctecli_rfc, :string, size: 20, null: true
      add :ctecli_codigo_k, :string, size: 50, null: true
      add :ctedir_codigo_k, :string, size: 50, null: true
      add :ctecli_dencomercia, :string, size: 200, null: true
      add :cadena, :string, size: 100, null: true
      add :tipo, :string, size: 50, null: true
      add :canal, :string, size: 50, null: true
      add :paquete, :string, size: 50, null: true
      add :frecuencia, :string, size: 50, null: true
      add :pround_codigo_k, :string, size: 50, null: true
      add :produc_codigo_k, :string, size: 50, null: true
      add :produc_descripcion, :string, size: 200, null: true
      add :marca, :string, size: 100, null: true
      add :presentacion, :string, size: 100, null: true
      add :sabor, :string, size: 100, null: true
      add :fabricante, :string, size: 100, null: true
      add :segmento, :string, size: 100, null: true
      add :linea, :string, size: 100, null: true
      add :pzaprev, :integer, null: true
      add :vtaprev, :decimal, precision: 15, scale: 2, null: true
      add :pzaliq, :integer, null: true
      add :vtaliq, :decimal, precision: 15, scale: 2, null: true
      add :pedcted_desc1, :string, size: 200, null: true
      add :map_x, :decimal, precision: 15, scale: 6, null: true
      add :map_y, :decimal, precision: 15, scale: 6, null: true
      add :rechazo, :decimal, precision: 15, scale: 2, null: true
      add :descuento, :decimal, precision: 15, scale: 2, null: true

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true

      add :estado_id, references(:meta_schema_estados), null: true

      add :fecha_registro, :utc_datetime, null: true

    end

    # SIN índice único de negocio (a diferencia del default que arma
    # CatalogoGenerador para cualquier catálogo nuevo) -- con 38 campos
    # reales, un índice que los combine TODOS excede el límite de 32
    # columnas por índice de Postgres (error real al generar: "no se
    # puede usar más de 32 columnas en un índice"). Además, semánticamente
    # tampoco correspondía: "historico" es una tabla de datos
    # históricos/importados, donde repetir la misma combinación de
    # campos en momentos distintos es esperable, no un error de
    # duplicado. Si más adelante hace falta evitar duplicados por una
    # clave natural específica (unos pocos campos, no los 38), se puede
    # agregar un índice único acotado a esos campos en una migración
    # aparte.

  end
end
