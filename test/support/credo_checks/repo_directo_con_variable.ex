defmodule MetadataApp.CredoChecks.RepoDirectoConVariable do
  @moduledoc """
  Guardrail estructural (Fase 5 del modelo de Alcance de Datos,
  2026-08-11) — flaguea `Repo.get/get!/get_by/get_by!` cuando el schema
  se resuelve en una VARIABLE (`Repo.get(modulo, id)`) en vez de un alias
  de módulo literal (`Repo.get(MetadataApp.MetaSchema.Auditoria, id)`).

  Por qué esta forma y no "prohibir Repo.* fuera de CatalogoGenerico"
  (la primera idea, descartada): este proyecto tiene decenas de contextos
  legítimos (`Autenticacion`, `Permissions`, `Integraciones`...) que
  llaman `Repo` directo contra SUS PROPIAS tablas de sistema — un check
  así habría producido cientos de falsos positivos, inútil en la
  práctica. La señal real no es "¿tocaste Repo?", es "¿el schema que
  estás consultando es una variable resuelta en runtime?" — un alias
  literal SIEMPRE es una tabla de sistema fija (Usuario, Auditoria,
  Header...); una variable (`modulo`, `schema_mod`, `detalle_modulo`...)
  puede ser CUALQUIER catálogo generado, incluido uno con
  `alcance_habilitado: true` — y `Repo.get(modulo, id)` salta por completo
  `CatalogoGenerico.obtener!/3`, sin aplicar ningún alcance.

  Encontró 2 casos reales al escribirse (`ficha_live.ex` línea ~355,
  `buscador_trn_live.ex` líneas ~79/102) — ver el commit de la Fase 5 para
  cómo se resolvió cada uno (fix real o excepción documentada).

  Corre con `MIX_ENV=test mix credo --strict` -- este archivo vive en
  `test/support/` (no en `lib/`) a propósito: depende de `Credo.Check`,
  que no es una dependencia de producción, así que no puede compilar bajo
  `MIX_ENV=prod`.
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      `Repo.get/get!/get_by/get_by!` con un schema resuelto en variable
      salta por completo el Alcance de Datos (CatalogoGenerico.obtener!/3),
      que es el único choke point que aplica el filtro de
      lectura/escritura por (rol, catálogo). Si el módulo detrás de la
      variable es un catálogo generado con alcance_habilitado: true, un
      usuario puede terminar viendo/editando filas fuera de su alcance
      sin que nada lo bloquee.

      Si el schema es fijo (una tabla de sistema conocida, ej.
      `MetadataApp.Autenticacion.Usuario`), escribilo como alias literal
      -- Repo.get(MiSchema, id) -- eso no dispara este check.

      Si de verdad necesitás resolver el catálogo dinámicamente, pasá por
      MetadataApp.BusinessProcessBuilder.CatalogoGenerico.obtener!/3 (o
      MetaBcApi.obtener/2 si es una regla de negocio interna, con
      scope: :sistema).
      """
    ]

  @funciones_flageadas ~w(get get! get_by get_by!)a

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
  end

  # Repo.get(modulo, id) / Repo.get!(modulo, id) / Repo.get_by(modulo, opts) /
  # Repo.get_by!(modulo, opts) -- primer argumento es una VARIABLE (3-tupla
  # {nombre, meta, contexto} con contexto atómico, no una lista de args ni
  # un alias `{:__aliases__, _, _}`).
  defp traverse(
         {{:., _, [{:__aliases__, _, [:Repo]}, funcion]}, meta, [{schema_var, _, contexto} | _rest]} = ast,
         issues,
         issue_meta
       )
       when funcion in @funciones_flageadas and is_atom(schema_var) and is_atom(contexto) do
    {ast, [emitir(issue_meta, meta, funcion, schema_var) | issues]}
  end

  defp traverse(ast, issues, _issue_meta), do: {ast, issues}

  defp emitir(issue_meta, meta, funcion, schema_var) do
    format_issue(
      issue_meta,
      message:
        "Repo.#{funcion}(#{schema_var}, ...) resuelve el schema en runtime -- salta el Alcance de Datos. " <>
          "Si #{schema_var} puede ser un catálogo generado, usá CatalogoGenerico.obtener!/3 (o MetaBcApi con scope: :sistema).",
      trigger: "Repo.#{funcion}",
      line_no: meta[:line]
    )
  end
end
