defmodule Mix.Tasks.Motor.Reglas.Andamiar do
  use Mix.Task
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.MetaEstadosAdmin

  @shortdoc "Genera stubs de reglas PRE/POST para las transiciones de un catálogo que todavía no tienen una"

  @moduledoc """
  Uso: mix motor.reglas.andamiar <catalogo>

  Para cada transición del catálogo que todavía no tenga una regla "pre"
  o "post" enganchada, genera un módulo stub
  (`lib/metadata_app/meta_business_process/reglas/<catalogo>/<accion>_pre.ex`
  y `..._post.ex`, con un `# ESCRIBA SUS REGLAS AQUI` donde va la lógica
  de negocio) y lo engancha automáticamente vía
  `meta_schema_transicion_reglas`. El cuerpo por defecto es un no-op
  (`:ok` / `{:ok, :sin_cambios}`) — el autómata sigue funcionando igual
  si nadie completa el stub.

  Seguro de re-correr:
    - NUNCA sobrescribe un archivo que ya existe (podría ser lógica de
      negocio real ya escrita).
    - NUNCA engancha una segunda regla si la transición ya tiene una de
      ese tipo (pre/post), tenga el nombre que tenga.
    - Si dos transiciones del catálogo comparten la misma "accion"
      (distinto estado de origen), se saltan con una advertencia — el
      nombre del archivo no alcanzaría para distinguirlas, hay que
      engancharlas a mano.
  """

  def run([]), do: Mix.raise("Uso: mix motor.reglas.andamiar <catalogo>")

  def run([catalogo | _resto]) do
    Mix.Task.run("app.config")

    {:ok, resultado, _apps} =
      Ecto.Migrator.with_repo(MetadataApp.Repo, fn _repo -> andamiar(catalogo) end)

    case resultado do
      {:error, motivo} -> Mix.raise(motivo)
      :ok -> :ok
    end
  end

  defp andamiar(catalogo) do
    case MetaSchemaContext.obtener_header_por_nombre(catalogo) do
      nil ->
        {:error, "catálogo no encontrado: #{catalogo}"}

      header ->
        transiciones = MetaEstadosAdmin.listar_transiciones(header.id)

        if transiciones == [] do
          Mix.shell().info("\"#{catalogo}\" no tiene transiciones todavía — nada que andamiar.")
        else
          repetidas =
            transiciones
            |> Enum.frequencies_by(& &1.accion)
            |> Enum.filter(fn {_accion, n} -> n > 1 end)
            |> Enum.map(&elem(&1, 0))
            |> MapSet.new()

          Enum.each(transiciones, &andamiar_transicion(catalogo, &1, repetidas))
        end

        :ok
    end
  end

  defp andamiar_transicion(catalogo, transicion, repetidas) do
    if MapSet.member?(repetidas, transicion.accion) do
      Mix.shell().info(
        "  (salteada \"#{transicion.accion}\": hay más de una transición con esta acción en #{catalogo}, enganchá a mano)"
      )
    else
      andamiar_pre(catalogo, transicion)
      andamiar_post(catalogo, transicion)
    end
  end

  defp andamiar_pre(catalogo, transicion) do
    if Enum.any?(transicion.reglas, &(&1.tipo == "pre")) do
      Mix.shell().info("  = #{catalogo} \"#{transicion.accion}\": ya tiene una regla pre enganchada, sin tocar")
    else
      nombre_regla = "#{transicion.accion}_pre"

      contenido = """
      defmodule MetadataApp.MetaBusinessProcess.Reglas.#{Macro.camelize(catalogo)}.#{Macro.camelize(nombre_regla)} do
        @behaviour MetadataApp.MetaStateEngine.ReglaPre

        @impl true
        def evaluar(_registro, _contexto, _params) do
          # ESCRIBA SUS REGLAS AQUI
          :ok
        end
      end
      """

      ruta = ruta_regla(catalogo, nombre_regla)
      creado? = escribir_si_no_existe(ruta, contenido)
      enganchar(transicion.id, "pre", nombre_regla)

      estado = if creado?, do: "stub creado y enganchado", else: "archivo ya existía, solo se enganchó"
      Mix.shell().info("  + #{catalogo} \"#{transicion.accion}\" (pre): #{estado} (#{ruta})")
    end
  end

  defp andamiar_post(catalogo, transicion) do
    if Enum.any?(transicion.reglas, &(&1.tipo == "post")) do
      Mix.shell().info("  = #{catalogo} \"#{transicion.accion}\": ya tiene una regla post enganchada, sin tocar")
    else
      nombre_regla = "#{transicion.accion}_post"

      contenido = """
      defmodule MetadataApp.MetaBusinessProcess.Reglas.#{Macro.camelize(catalogo)}.#{Macro.camelize(nombre_regla)} do
        @behaviour MetadataApp.MetaStateEngine.ReglaPost

        @impl true
        def ejecutar(_registro, _contexto, _params, _repo) do
          # ESCRIBA SUS REGLAS AQUI
          {:ok, :sin_cambios}
        end
      end
      """

      ruta = ruta_regla(catalogo, nombre_regla)
      creado? = escribir_si_no_existe(ruta, contenido)
      enganchar(transicion.id, "post", nombre_regla)

      estado = if creado?, do: "stub creado y enganchado", else: "archivo ya existía, solo se enganchó"
      Mix.shell().info("  + #{catalogo} \"#{transicion.accion}\" (post): #{estado} (#{ruta})")
    end
  end

  defp ruta_regla(catalogo, nombre_regla) do
    Path.join(["lib", "metadata_app", "meta_business_process", "reglas", catalogo, "#{nombre_regla}.ex"])
  end

  # Devuelve true si escribió el archivo (no existía), false si ya existía
  # y se lo dejó intacto — nunca sobrescribe.
  defp escribir_si_no_existe(ruta, contenido) do
    if File.exists?(ruta) do
      false
    else
      File.mkdir_p!(Path.dirname(ruta))
      File.write!(ruta, contenido)
      true
    end
  end

  defp enganchar(transicion_id, tipo, regla) do
    case MetaEstadosAdmin.crear_regla(%{
           "transicion_id" => transicion_id,
           "tipo" => tipo,
           "regla" => regla,
           "orden" => 0
         }) do
      {:ok, _regla} -> :ok
      {:error, changeset} -> Mix.raise("no se pudo enganchar #{tipo}/#{regla}: #{inspect(changeset.errors)}")
    end
  end
end
