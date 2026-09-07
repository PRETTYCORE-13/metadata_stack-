defmodule Mix.Tasks.Motor.Publicar do
  use Mix.Task
  alias MetadataApp.MetaPublicador

  @shortdoc "Empaqueta uno o más BC (schema+migraciones+autómata+reglas) y los despliega directo a producción"

  @moduledoc """
  Uso: mix motor.publicar --sistema=<sistema> <catalogo> [<catalogo2> ...]

  Lleva uno o más Business Context (BC) construidos localmente con el BPB
  a Linux Trixie (producción) — **sin** pasar por el repo compartido
  `metadata_stack-` (ningún `pty_*` va a git, ver docs/roadmap.md
  #7 y la memoria de proyecto `project_git_cicd_pty_cleanup`).

  `--sistema=` es OBLIGATORIO, sin default (SPEC-SYS-0309202601, R5) — con
  varios sistemas de cliente en el mismo clúster, un default silencioso es
  la forma más fácil de mandarle una actualización al cliente equivocado.
  Se valida con `MetadataApp.MotorAlta.publicable?/1` antes de tocar nada
  -- un cliente real de `priv/sistemas.json`, o `"unstable"` (R10,
  2026-09-07: probar un BC antes de mandarlo a cualquier cliente real) --
  nunca `"testing"`/`"stable"`, esos dos solo reciben por promoción
  (`mix motor.promover`). Un nombre que no cumple ninguna de las dos se
  rechaza acá, nunca llega a armar ni disparar nada.

  Pasos (la lógica vive en `MetadataApp.MetaPublicador`, compartida con el
  futuro wizard de publicación en BC List — este task es solo la interfaz
  de línea de comandos):
    1. `MetaPublicador.validar/1` sobre los catálogos pedidos — aborta si
       hay errores estructurales. Cada uno que sea maestro de catálogos
       detalle los incluye automáticamente (mismo criterio que
       "Despliegue" en BcListLive), y cualquier campo tipo `referencia`
       (del catálogo o de sus detalles) también arrastra al catálogo
       referenciado, recursivo — si el catálogo destino nunca se desplegó
       antes, su migración crea una FK contra una tabla que en producción
       todavía no existe (encontrado real: la primera prueba de este
       mecanismo). El paquete final queda en orden topológico
       (`MetaSchemaContext.calcular_paquete_publicacion/1`).
    2. `mix gen.catalogos` — re-sincroniza cada schema `.ex` ya generado
       contra la metadata actual antes de empaquetar nada (encontrado real:
       un catálogo detalle cuyo `.ex` se había generado ANTES de quedar
       enlazado a su maestro se publicó sin `encabezado_id`/`renglon_id` en
       el schema Ecto — la tabla física sí los tenía, pero el módulo
       compilado no). Sin este paso, `motor.publicar` empaqueta ciegamente
       lo que haya en disco, esté o no al día.
    3. `mix meta.export` + `mix motor.export` (de TODOS los catálogos, como
       siempre — solo cambia en disco el archivo del que de verdad se tocó).
    4. `MetaPublicador.armar_bundle/1` — un `.tar.gz` con, por cada catálogo
       en alcance: su schema, sus migraciones, su `.meta.json`
       (+ `.motor.json` si tiene autómata propio — un detalle no), y su
       carpeta de reglas de negocio si existe.
    5. `MetaPublicador.disparar_deploy/3` — dispara
       `.github/workflows/bc-deploy.yml` (GitHub Actions) vía
       `gh workflow run`, mandando el bundle en base64 como input — ese
       workflow extrae el bundle SOBRE un checkout efímero de `main`,
       compila, arma la imagen Docker y la despliega, todo dentro de un
       runner que se destruye al terminar. `origin/main` nunca se entera:
       ni un `git add`, ni un commit, ni un push en ningún paso de acá.

  Requiere `gh` (GitHub CLI) autenticado con acceso al repo — mismo binario
  que ya se usa para administrar el resto del proyecto. Los 3 secrets que
  el workflow necesita (`DEPLOY_HOST`/`DEPLOY_USER`/`DEPLOY_SSH_KEY`) ya
  están configurados desde el primer deploy real del BPB — este task no
  necesita ni ve ninguna credencial de producción, corren enteras del lado
  de GitHub Actions.
  """

  def run(args) do
    Mix.Task.run("app.config")

    {switches, nombres, _} = OptionParser.parse(args, strict: [sistema: :string])
    sistema = switches[:sistema]

    cond do
      is_nil(sistema) ->
        Mix.raise("Falta --sistema=<sistema>, obligatorio. Uso: mix motor.publicar --sistema=<sistema> <catalogo> [<catalogo2> ...]")

      nombres == [] ->
        Mix.raise("Uso: mix motor.publicar --sistema=<sistema> <catalogo> [<catalogo2> ...]")

      not MetadataApp.MotorAlta.publicable?(sistema) ->
        Mix.raise(
          "\"#{sistema}\" no está de alta (no aparece en priv/sistemas.json) ni es \"unstable\" -- " <>
            "no se puede publicar ahí. \"testing\"/\"stable\" nunca reciben una publicación directa, solo por promoción (mix motor.promover)."
        )

      true ->
        publicar(sistema, nombres)
    end
  end

  defp publicar(sistema, nombres) do
    Mix.shell().info("== validando #{Enum.join(nombres, ", ")} ==")

    {:ok, resultado, _apps} =
      Ecto.Migrator.with_repo(MetadataApp.Repo, fn _repo -> MetaPublicador.validar(nombres) end)

    case resultado do
      {:error, mensaje} ->
        Mix.raise(mensaje)

      {:ok, %{catalogos: catalogos, problemas: problemas}} ->
        Enum.each(problemas, fn p ->
          etiqueta = if p.severidad == :error, do: "ERROR", else: "advertencia"
          Mix.shell().info("  [#{etiqueta}] #{p.mensaje}")
        end)

        if problemas == [], do: Mix.shell().info("  sin problemas")

        automaticos = catalogos -- nombres

        if automaticos != [] do
          Mix.shell().info("  incluye automáticamente: #{Enum.join(automaticos, ", ")}")
        end

        Mix.shell().info("\n== re-sincronizando schemas contra la metadata actual ==")
        Mix.Task.rerun("gen.catalogos")

        Mix.shell().info("\n== exportando catálogos + autómata ==")
        Mix.Task.rerun("meta.export")
        Mix.Task.rerun("motor.export")

        Mix.shell().info("\n== armando bundle ==")
        armar_y_desplegar(sistema, nombres, catalogos)
    end
  end

  defp armar_y_desplegar(sistema, nombres, catalogos) do
    case MetaPublicador.armar_bundle(catalogos) do
      {:error, mensaje} ->
        Mix.raise(mensaje)

      {:ok, bundle_path} ->
        Mix.shell().info("  #{bundle_path} (#{MetaPublicador.tamanio_legible(bundle_path)})")
        Mix.shell().info("\n== guardando bundle en GitHub Releases (bc-<catálogo>) ==")

        case MetaPublicador.persistir_bundle(nombres, bundle_path) do
          {:error, mensaje} ->
            Mix.raise(mensaje)

          {:ok, tags} ->
            Mix.shell().info("  #{Enum.join(tags, ", ")}")
            Mix.shell().info("\n== disparando BC Deploy en GitHub Actions para \"#{sistema}\" ==")

            case MetaPublicador.disparar_deploy(sistema, nombres, bundle_path) do
              {:ok, salida} ->
                Mix.shell().info(salida)

                Mix.shell().info(
                  "Disparado — #{Enum.join(nombres, ", ")} va(n) camino a \"#{sistema}\". " <>
                    "Seguí el progreso con \"gh run list\" / \"gh run watch\"."
                )

              {:error, mensaje} ->
                Mix.raise(mensaje)
            end
        end
    end
  end
end
