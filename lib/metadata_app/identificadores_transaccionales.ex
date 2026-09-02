defmodule MetadataApp.IdentificadoresTransaccionales do
  @moduledoc """
  SPEC-SYS-0109202601 (Administrador de Folios) — único punto de
  entrada que asigna TRN y Folio a un registro transaccional, DENTRO
  de la misma transacción de base de datos que lo crea (design.md
  §1.2). Reemplaza a `MetadataApp.TRN.asignar_si_transaccional/1` como
  punto de enganche desde `CatalogoGenerico.crear_con_attrs_preparados/5`
  — `MetadataApp.TRN` sigue existiendo, solo cambia quién lo llama.

  ## Por qué alcanza con reusar `TRN.asignar_si_transaccional/1` tal cual

  `asignar_si_transaccional/1` ya envuelve su lógica en
  `Repo.transaction(fn -> ... end)`. Ecto NO abre una transacción real
  anidada cuando eso corre DENTRO de una transacción ya abierta (el
  `Repo.transaction/1` de más afuera) — ejecuta la función en la MISMA
  transacción, y un `Repo.rollback/1` adentro aborta esa MISMA
  transacción externa. Por eso no hizo falta "adaptar" el reintento de
  TRN como preveía design.md §1.2/§5 — compone solo, sin tocar
  `MetadataApp.TRN`.

  ## Contrato de `asignar/4`

  `asignar(repo, registro, header, contexto \\\\ %{})` — pensado para
  correr como paso de un `Ecto.Multi.run/3` (que ya inyecta `repo`) o
  inline dentro de un `Repo.transaction(fn -> ... end)` (pasando el
  módulo `Repo`). Devuelve `{:ok, registro_actualizado} | {:error,
  motivo}` — NUNCA llama `Repo.rollback/1` por su cuenta; quien lo
  invoca decide cómo traducir un `{:error, _}` en rollback (mismo
  patrón que ya usan los demás pasos de `crear_simple/3`).
  """

  import Ecto.Query
  alias MetadataApp.TRN
  alias MetadataApp.MetaSchema.Transicion
  alias MetadataApp.IdentificadoresTransaccionales.{FolioPerfil, FolioHistorial}

  @doc "Ver moduledoc — corre TRN (si `schema_es_transaccional`) y Folio (si además `requiere_folio`), en ese orden, dentro de la transacción en curso."
  def asignar(repo, registro, header, _contexto \\ %{}) do
    with {:ok, registro} <- asignar_trn_si_transaccional(registro, header),
         {:ok, registro} <- asignar_folio_si_configurado(repo, registro, header) do
      {:ok, registro}
    end
  end

  defp asignar_trn_si_transaccional(registro, %{schema_es_transaccional: true}) do
    TRN.asignar_si_transaccional({:ok, registro})
  end

  defp asignar_trn_si_transaccional(registro, _header), do: {:ok, registro}

  defp asignar_folio_si_configurado(repo, registro, %{requiere_folio: true} = header) do
    asignar_folio(repo, registro, header)
  end

  defp asignar_folio_si_configurado(_repo, registro, _header), do: {:ok, registro}

  # design.md §3.2 — resolución + lock + incremento + historial, todo
  # dentro de la transacción que ya está abierta (nunca abre la suya
  # propia, a diferencia de TRN).
  defp asignar_folio(repo, registro, header) do
    subtipo_id = Map.get(registro, :subtipo_transaccion, nil)
    branch_id = Map.get(registro, :branch_id, nil)

    with :ok <- verificar_subtipo_activo(repo, subtipo_id),
         {:ok, perfil} <- resolver_perfil(repo, header.id, subtipo_id, branch_id) do
      # SELECT ... FOR UPDATE -- unidad real de bloqueo (R3): dos
      # perfiles distintos nunca contienden, solo dos pedidos para el
      # MISMO perfil serializan acá.
      perfil_bloqueado =
        from(p in FolioPerfil, where: p.id == ^perfil.id, lock: "FOR UPDATE")
        |> repo.one!()

      # GREATEST(numero_actual, numero_inicial - 1) + 1 en vez de un
      # simple +1: numero_actual arranca en el default físico 0 (nunca
      # se "siembra" con numero_inicial al crear el perfil, no hace
      # falta), así que el primer pedido tiene que respetar
      # numero_inicial igual. Después del primer folio, numero_actual
      # siempre es >= numero_inicial - 1, así que GREATEST no vuelve a
      # cambiar nada (coherente con design.md §2.1: numero_inicial no
      # se reusa después del primer folio).
      {1, [numero]} =
        from(p in FolioPerfil, where: p.id == ^perfil_bloqueado.id, select: p.numero_actual)
        |> update([p], set: [numero_actual: fragment("GREATEST(?, ? - 1) + 1", p.numero_actual, p.numero_inicial)])
        |> repo.update_all([])

      historial_attrs = %{
        pty_folio_perfiles_id: perfil.id,
        meta_schema_header_id: header.id,
        subtipo_transaccion_id: subtipo_id,
        branch_id: branch_id,
        serie: perfil.serie,
        folio: numero,
        entity_id: registro.id,
        trn: Map.get(registro, :trn)
      }

      case %FolioHistorial{} |> FolioHistorial.changeset(historial_attrs) |> repo.insert() do
        {:ok, _historial} ->
          registro
          |> Ecto.Changeset.change(%{folio_serie: perfil.serie, folio_numero: numero})
          |> repo.update()

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  # Un subtipo "dado de baja" no puede foliar por NINGÚN canal (a pedido
  # explícito, 2026-09-01), aunque tenga un perfil configurado -- se corta
  # ACÁ, antes de tocar el perfil (sin lock, sin incremento). "dado de
  # baja" = el `estado_id` ACTUAL del subtipo es el `estado_destino_id`
  # de SU transición con `accion == "baja"` -- no compara por el nombre
  # del estado (frágil si alguien lo renombra), mismo criterio que
  # `transicion_alta/1` en MetaStateEngine usa el nombre de la ACCIÓN,
  # nunca el del estado. `nil` (catálogo sin subtipo configurado) pasa
  # de largo -- no hay nada que verificar.
  defp verificar_subtipo_activo(_repo, nil), do: :ok

  defp verificar_subtipo_activo(repo, subtipo_id) do
    dado_de_baja? =
      from(s in "pty_subtipos_transaccion",
        join: t in Transicion,
        on: t.estado_destino_id == s.estado_id,
        where: s.id == ^subtipo_id and t.accion == "baja" and is_nil(t.delete_guid)
      )
      |> repo.exists?()

    if dado_de_baja?, do: {:error, :subtipo_dado_de_baja}, else: :ok
  end

  # design.md §3.1 — resolución de perfil, los tres exactos primero;
  # si Sucursal no matchea, cae a global (branch_id: nil) para el MISMO
  # header+subtipo. Subtipo NUNCA tiene fallback (decisión confirmada).
  defp resolver_perfil(repo, header_id, subtipo_id, branch_id) do
    case buscar_perfiles(repo, header_id, subtipo_id, branch_id) do
      [] when not is_nil(branch_id) -> repo |> buscar_perfiles(header_id, subtipo_id, nil) |> uno_o_error()
      candidatos -> uno_o_error(candidatos)
    end
  end

  defp uno_o_error([perfil]), do: {:ok, perfil}
  defp uno_o_error([]), do: {:error, :perfil_no_encontrado}
  defp uno_o_error(_varios), do: {:error, :configuracion_ambigua}

  defp buscar_perfiles(repo, header_id, subtipo_id, branch_id) do
    from(p in FolioPerfil, where: p.documento == ^header_id and is_nil(p.delete_guid))
    |> filtrar_subtipo(subtipo_id)
    |> filtrar_branch(branch_id)
    |> repo.all()
  end

  defp filtrar_subtipo(query, nil), do: where(query, [p], is_nil(p.subtipo_transaccion))
  defp filtrar_subtipo(query, subtipo_id), do: where(query, [p], p.subtipo_transaccion == ^subtipo_id)

  defp filtrar_branch(query, nil), do: where(query, [p], is_nil(p.sucursal))
  defp filtrar_branch(query, branch_id), do: where(query, [p], p.sucursal == ^branch_id)
end
