defmodule Mix.Tasks.Motor.GenerarDropHuerfano do
  use Mix.Task
  alias MetadataApp.BusinessProcessBuilder.{CatalogoGenerador, MetaSchemaContext}

  @shortdoc "Genera (y corre local) la migración de DROP de un catálogo sin header local"

  @moduledoc """
  Uso: mix motor.generar_drop_huerfano <catalogo> --confirmar=<catalogo>

  SPEC-SYS-1809202601 -- para un catálogo que quedó HUÉRFANO en algún
  ambiente desplegado (existe ahí como header + tabla física) pero YA
  NO EXISTE en ningún lado local -- caso real: un catálogo renombrado
  "en el mismo registro" (`UPDATE`, no `crear` + `Eliminar`) deja el
  nombre viejo vivo en cualquier ambiente que ya lo tenía publicado
  antes del rename. Ni "Eliminar" de BC List ni `mix motor.despublicar`
  cubren esto: los dos asumen que el catálogo SÍ existe local (el
  primero para poder borrarlo, el segundo para encontrar la migración
  de `DROP` que "Eliminar" ya dejó).

  Genera esa misma migración de `DROP` -- `CatalogoGenerador.
  generar_migracion_drop/1`, la misma función que usa "Eliminar", que
  YA funciona por nombre sin exigir un header local (`purgar_metadata_
  por_nombre/1`, que corre DENTRO de la migración generada, no-opea si
  el header no existe) -- y la corre local ya mismo (limpia cualquier
  tabla física huérfana que también haya quedado local, y confirma que
  la migración compila/corre antes de mandarla a cualquier lado).

  Este task NO dispara ningún deploy. Para propagar el borrado a un
  ambiente puntual, una vez generada la migración:

      mix motor.despublicar --sistema=<sistema> <catalogo>

  (reusado SIN NINGÚN CAMBIO -- nunca miró si el catálogo es `pty_*`,
  solo que exista esa migración). Si el catálogo no es `pty_*`/
  `demo100_*` (no está gitignored), además conviene commitear/pushear
  la migración a git, para que llegue a `testing`/`stable` por
  promoción normal y a cualquier checkout nuevo -- el `motor.
  despublicar` de arriba solo resuelve "ya, ahora, en un ambiente
  puntual".

  `--confirmar=<catalogo>` es OBLIGATORIO y tiene que coincidir
  EXACTO con `<catalogo>` -- nunca un prompt interactivo (frágil en
  PowerShell/Windows), mismo criterio de "confirmar tecleando el
  nombre" que ya usa "Eliminar" en BC List.
  """

  def run(args) do
    Mix.Task.run("app.config")

    {switches, nombres, _} = OptionParser.parse(args, strict: [confirmar: :string])
    confirmar = switches[:confirmar]

    cond do
      nombres == [] or length(nombres) > 1 ->
        Mix.raise("Uso: mix motor.generar_drop_huerfano <catalogo> --confirmar=<catalogo>")

      is_nil(confirmar) ->
        Mix.raise("Falta --confirmar=<catalogo>, obligatorio -- tiene que coincidir exacto con el nombre del catálogo.")

      confirmar != hd(nombres) ->
        Mix.raise("--confirmar=\"#{confirmar}\" no coincide con \"#{hd(nombres)}\" -- nada se generó.")

      true ->
        generar(hd(nombres))
    end
  end

  defp generar(catalogo) do
    {:ok, existe_local?, _apps} =
      Ecto.Migrator.with_repo(MetadataApp.Repo, fn _repo ->
        MetaSchemaContext.obtener_header_por_nombre(catalogo) != nil
      end)

    if existe_local? do
      Mix.raise(
        "\"#{catalogo}\" TODAVÍA existe local -- este task es para un catálogo huérfano " <>
          "(vivo en algún ambiente desplegado, ausente en TODOS lados local). Para borrar uno " <>
          "que sí existe acá, usá \"BC List → Eliminar\" (que ya deja la migración de DROP lista " <>
          "para \"mix motor.despublicar\")."
      )
    end

    path = CatalogoGenerador.generar_migracion_drop(catalogo)
    Mix.shell().info("== migración escrita: #{path} ==")
    Mix.shell().info("== corriéndola local ==")

    case CatalogoGenerador.migrar_capturando_fk() do
      :ok ->
        Mix.shell().info(
          "Listo -- \"#{catalogo}\" ya no existe local (ni header ni tabla, si la había).\n\n" <>
            "Para propagar a un ambiente puntual:\n" <>
            "  mix motor.despublicar --sistema=<sistema> #{catalogo}\n\n" <>
            "Si \"#{catalogo}\" no es pty_*/demo100_* (no está gitignored), además commiteá/pusheá " <>
            "#{path} para que llegue a testing/stable por promoción normal."
        )

      {:error, mensaje} ->
        File.rm(path)
        Mix.raise(mensaje)
    end
  end
end
