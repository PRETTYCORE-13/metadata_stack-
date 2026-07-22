defmodule MetadataApp.TRN do
  @moduledoc """
  Único responsable autorizado de generar y persistir referencias
  transaccionales (TRN) — ver `MetadataApp.Transaction` para el behaviour
  declarativo que cada schema de catálogo transaccional implementa.
  Ningún otro módulo arma un TRN a mano.

  Formato público: `CCCC-YYMMDD-HHMMSS-RRRR` (ej.
  `VENT-260721-104537-4832`). Identificador técnico interno: ULID
  (ordenable por tiempo — ver dependencia `ulid`), para correlación,
  Event Sourcing y APIs externas.

  Regla #3 (inmutable): `trn`/`ulid` NUNCA se tocan después de asignados
  — no son parte de `@campos` en el schema generado (mismo criterio ya
  usado para `estado_id`), así que ningún PATCH puede pisarlos (ver
  `CatalogoGenerico.actualizar/2`, `rechazar_no_editables/4`).
  """

  import Ecto.Query
  alias MetadataApp.Repo
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.MetaSchema.TransactionRegistry

  @intentos_maximos 5

  @doc """
  Si el catálogo de `registro` es transaccional
  (`schema_es_transaccional` en `meta_schema_header`), le asigna
  `trn`/`ulid` recién generados y espeja una fila en
  `meta_schema_transaction_registry` — todo en una sola transacción. Si el catálogo
  NO es transaccional, no hace nada (pass-through). Se llama siempre
  desde `CatalogoGenerico.crear/2`, nunca a mano desde otro lado —
  Regla #1: ninguna operación transaccional nace sin TRN.
  """
  def asignar_si_transaccional({:error, _} = error), do: error

  def asignar_si_transaccional({:ok, registro}) do
    catalogo = registro.__struct__.__schema__(:source)
    header = MetaSchemaContext.obtener_header_por_nombre(catalogo)

    if header && header.schema_es_transaccional do
      Repo.transaction(fn -> asignar(registro, header, 1) end)
    else
      {:ok, registro}
    end
  end

  defp asignar(_registro, _header, intento) when intento > @intentos_maximos do
    Repo.rollback("no se pudo generar un TRN único después de #{@intentos_maximos} intentos")
  end

  # Paso 5 de la estrategia de generación (validar unicidad, reintentar si
  # choca): el índice único de la tabla es la fuente de verdad final —
  # ante una colisión de verdad improbable (aleatorio + mismo segundo)
  # simplemente se regenera con un aleatorio nuevo, no hace falta lockear
  # nada de antemano.
  defp asignar(registro, header, intento) do
    trn = generar_trn(header.codigo_trn)
    ulid = Ulid.generate()

    resultado =
      registro
      |> Ecto.Changeset.change(%{trn: trn, ulid: ulid})
      |> Ecto.Changeset.unique_constraint(:trn, name: nombre_indice(header.schema_context_name, "trn"))
      |> Ecto.Changeset.unique_constraint(:ulid, name: nombre_indice(header.schema_context_name, "ulid"))
      |> Repo.update()

    case resultado do
      {:ok, actualizado} ->
        insertar_registro_central(actualizado, header, trn, ulid)
        actualizado

      {:error, %Ecto.Changeset{errors: errores} = changeset} ->
        if Keyword.has_key?(errores, :trn) or Keyword.has_key?(errores, :ulid) do
          asignar(registro, header, intento + 1)
        else
          Repo.rollback(changeset)
        end
    end
  end

  defp insertar_registro_central(registro, header, trn, ulid) do
    %TransactionRegistry{}
    |> Ecto.Changeset.change(%{
      ulid: ulid,
      trn: trn,
      meta_schema_header_id: header.id,
      entity_id: registro.id
    })
    |> Repo.insert!()
  end

  # Paso 1-4: código de módulo + timestamp UTC + aleatorio de 4 dígitos.
  defp generar_trn(codigo) do
    fecha = Calendar.strftime(DateTime.utc_now(), "%y%m%d-%H%M%S")
    aleatorio = (:rand.uniform(10_000) - 1) |> Integer.to_string() |> String.pad_leading(4, "0")
    "#{codigo}-#{fecha}-#{aleatorio}"
  end

  @doc "Nombre determinista de los índices únicos trn/ulid de un catálogo — misma fuente de verdad para la migración y para el unique_constraint acá. Mismo criterio que CatalogoGenerador.nombre_indice_unico/1."
  def nombre_indice(tabla, campo), do: "#{tabla}_#{campo}_unico_index"

  # meta_schema_header_id en meta_schema_transaction_registry es
  # on_delete: :restrict a propósito (protege el índice central del uso
  # normal, mismo criterio que meta_schema_transicion_eventos) — esto lo
  # puentea deliberadamente, solo se llama desde un borrado total ya
  # confirmado por el usuario (ver CatalogoGenerador.eliminar/3).
  def purgar_registro_central(meta_schema_header_id) do
    Repo.delete_all(from t in "meta_schema_transaction_registry", where: t.meta_schema_header_id == ^meta_schema_header_id)
    :ok
  end
end
