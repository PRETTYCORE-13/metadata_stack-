defmodule Mix.Tasks.Motor.Tepache do
  use Mix.Task
  alias MetadataApp.MetaTepache

  @shortdoc "Empaqueta uno o más BC y los sube a GitHub Releases para previsualizar, SIN desplegar a producción"

  @moduledoc """
  Uso: mix motor.tepache <catalogo> [<catalogo2> ...] [--descripcion "texto"]

  Arma un "tepache" (bundle de previsualización) para que otro
  desarrollador lo importe en SU Postgres local y lo revise — a
  diferencia de `mix motor.publicar`, este task **nunca dispara
  `bc-deploy.yml`** ni toca producción (ver docs/roadmap.md #14).

  `--descripcion` es texto libre (motivo/impacto/notas) que queda primero
  en las notas del release, para que quien lo reciba sepa por qué se armó
  sin tener que preguntarte.

  La lógica vive en `MetadataApp.MetaTepache.exportar/2` — compartida con
  la pantalla "Tepache Exp/Imp" (Business Process Builder), este task es
  solo la interfaz de línea de comandos:
    1. `MetaPublicador.validar/1` — mismo cierre de dependencias
       (detalles + referencias) que la publicación real.
    2. Re-sincroniza cada schema `.ex` contra la metadata actual y
       exporta metadata+autómata (equivalente a `mix gen.catalogos` +
       `mix meta.export` + `mix motor.export`).
    3. `MetaPublicador.armar_bundle/1` — el mismo `.tar.gz` de siempre.
    4. Crea un release nuevo tageado `TEPACHE-NNNNNN` (consecutivo
       global, nunca el tag `bc-<catalogo>` de la publicación real) con
       notas describiendo qué trae, y le sube el bundle como asset
       `tepache.tar.gz`.

  Requiere `gh` (GitHub CLI) autenticado — mismo binario que ya usa
  `mix motor.publicar`.
  """

  def run(args) do
    {opts, nombres, _invalidos} = OptionParser.parse(args, strict: [descripcion: :string])
    descripcion = Keyword.get(opts, :descripcion, "")

    if nombres == [], do: Mix.raise("Uso: mix motor.tepache <catalogo> [<catalogo2> ...] [--descripcion \"texto\"]")

    Mix.Task.run("app.config")

    Mix.shell().info("== armando y publicando tepache de #{Enum.join(nombres, ", ")} ==")

    {:ok, resultado, _apps} =
      Ecto.Migrator.with_repo(MetadataApp.Repo, fn _repo -> MetaTepache.exportar(nombres, descripcion) end)

    case resultado do
      {:error, mensaje} ->
        Mix.raise(mensaje)

      {:ok, %{tag: tag, catalogos: catalogos, automaticos: automaticos, problemas: problemas}} ->
        Enum.each(problemas, fn p ->
          etiqueta = if p.severidad == :error, do: "ERROR", else: "advertencia"
          Mix.shell().info("  [#{etiqueta}] #{p.mensaje}")
        end)

        if problemas == [], do: Mix.shell().info("  sin problemas")
        if automaticos != [], do: Mix.shell().info("  incluye automáticamente: #{Enum.join(automaticos, ", ")}")

        Mix.shell().info("  paquete completo: #{Enum.join(catalogos, ", ")}")

        Mix.shell().info(
          "\nListo — #{tag}. Para que alguien lo importe: \"mix motor.tepache.importar #{tag}\"."
        )
    end
  end
end
