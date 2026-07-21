defmodule MetadataApp.MetaStateEngine.Reglas do
  @moduledoc """
  Punto único de despacho a las reglas PRE/POST de un catálogo (rediseño
  2026-07-21) — un catálogo tiene A LO SUMO un módulo Pre y un módulo Post,
  resueltos por convención de nombres:
  `MetadataApp.MetaBusinessProcess.Reglas.<Catalogo>.Pre` / `.Post`. Ya no
  hay vocabulario cerrado ni reglas configuradas fila por fila
  (`meta_schema_transicion_reglas` dejó de leerse acá) — todo es código
  libre con un `case` por `accion` adentro (ver `MetadataApp.MetaReglasCodigo`
  para el generador de stub/edición).

  Las 8 funciones que antes eran el "vocabulario cerrado"
  (`MetaStateEngine.Reglas.Pre`/`Post`) siguen existiendo tal cual, sin
  tocar — ya no se despachan automáticamente por nombre, pero cualquier
  código de catálogo las puede llamar directo como helper, ej.
  `MetadataApp.MetaStateEngine.Reglas.Pre.evaluar("campos_requeridos", registro, contexto, %{"campos" => [...]})`.

  Reglas no son obligatorias: si el catálogo nunca generó/compiló su
  módulo Pre/Post, se trata como "no hace nada" — `:ok` para PRE,
  `{:ok, :sin_cambios}` para POST.
  """

  @doc "Precondición: (accion, registro, contexto) -> :ok | {:error, mensaje}. Solo lectura."
  def evaluar_pre(accion, registro, contexto) do
    modulo = modulo_pre(catalogo_de(registro))

    if Code.ensure_loaded?(modulo) and function_exported?(modulo, :evaluar, 3) do
      modulo.evaluar(accion, registro, contexto)
    else
      :ok
    end
  end

  @doc "Postcondición: (accion, registro, contexto, repo) -> {:ok, cambios} | {:error, razon}."
  def ejecutar_post(accion, registro, contexto, repo) do
    modulo = modulo_post(catalogo_de(registro))

    if Code.ensure_loaded?(modulo) and function_exported?(modulo, :ejecutar, 4) do
      modulo.ejecutar(accion, registro, contexto, repo)
    else
      {:ok, :sin_cambios}
    end
  end

  @doc "Nombre del módulo Pre esperado para `catalogo` — pura construcción de nombre, no valida que exista."
  @spec modulo_pre(String.t()) :: module()
  def modulo_pre(catalogo), do: Module.concat([MetadataApp.MetaBusinessProcess.Reglas, Macro.camelize(catalogo), Pre])

  @doc "Nombre del módulo Post esperado para `catalogo` — pura construcción de nombre, no valida que exista."
  @spec modulo_post(String.t()) :: module()
  def modulo_post(catalogo), do: Module.concat([MetadataApp.MetaBusinessProcess.Reglas, Macro.camelize(catalogo), Post])

  defp catalogo_de(registro), do: registro.__struct__.__schema__(:source)
end
