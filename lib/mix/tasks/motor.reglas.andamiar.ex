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
      andamiar_tipo(catalogo, transicion, "pre")
      andamiar_tipo(catalogo, transicion, "post")
    end
  end

  # Delega la parte que importa (plantilla del stub + enganche) en
  # MetaEstadosAdmin.andamiar_regla_negocio/3 — así BcMotorLive puede
  # ofrecer el mismo "crear regla de negocio" de un click sin duplicar la
  # plantilla acá. Este task queda como wrapper fino: solo agrega la salida
  # por Mix.shell().
  defp andamiar_tipo(catalogo, transicion, tipo) do
    case MetaEstadosAdmin.andamiar_regla_negocio(catalogo, transicion, tipo) do
      {:ok, %{creado?: true, ruta: ruta}} ->
        Mix.shell().info("  + #{catalogo} \"#{transicion.accion}\" (#{tipo}): stub creado y enganchado (#{ruta})")

      {:ok, %{creado?: false, ruta: ruta}} ->
        Mix.shell().info("  + #{catalogo} \"#{transicion.accion}\" (#{tipo}): archivo ya existía, solo se enganchó (#{ruta})")

      {:error, :ya_tiene_regla} ->
        Mix.shell().info("  = #{catalogo} \"#{transicion.accion}\": ya tiene una regla #{tipo} enganchada, sin tocar")

      {:error, changeset} ->
        Mix.raise("no se pudo enganchar #{tipo} en \"#{transicion.accion}\": #{inspect(changeset.errors)}")
    end
  end
end
