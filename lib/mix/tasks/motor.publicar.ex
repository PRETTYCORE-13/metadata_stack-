defmodule Mix.Tasks.Motor.Publicar do
  use Mix.Task
  alias MetadataApp.MetaEstadosAdmin
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext

  @shortdoc "Empaqueta un BC (schema+migraciones+autómata+reglas) y lo despliega directo a producción"

  @moduledoc """
  Uso: mix motor.publicar <catalogo>

  Lleva un Business Context (BC) construido localmente con el BPB a Linux
  Trixie (producción) — **sin** pasar por el repo compartido
  `metadata_stack-` (ningún `pty_*` va a git, ver docs/roadmap.md
  #7 y la memoria de proyecto `project_git_cicd_pty_cleanup`). Reemplaza a
  la versión anterior de este mismo task (que armaba un `git commit` local
  del catálogo) — esa forma dejó de tener sentido el día que `pty_*` pasó a
  estar gitignored a propósito.

  Pasos:
    1. `MetaEstadosAdmin.validar_motor/1` sobre `<catalogo>` — aborta si hay
       errores estructurales. Si `<catalogo>` es maestro de uno o más
       catálogos detalle (`MetaSchemaContext.listar_catalogos_detalle/1`),
       se incluyen automáticamente — un detalle nunca se publica solo (mismo
       criterio que "Despliegue" en BcListLive). Cualquier campo tipo
       `referencia` (del catálogo o de sus detalles) también arrastra al
       catálogo referenciado, recursivo — si el catálogo destino nunca se
       desplegó antes, su migración crea una FK contra una tabla que en
       producción todavía no existe, y la migración completa del bundle
       falla (encontrado real: la primera prueba de este mecanismo).
    2. `mix gen.catalogos` — re-sincroniza cada schema `.ex` ya generado
       contra la metadata actual antes de empaquetar nada (encontrado real:
       un catálogo detalle cuyo `.ex` se había generado ANTES de quedar
       enlazado a su maestro se publicó sin `encabezado_id`/`renglon_id` en
       el schema Ecto — la tabla física sí los tenía, pero el módulo
       compilado no, y el motor tronaba con `ArgumentError: unknown field
       :encabezado_id` en cuanto alguien mandaba un alta con renglones).
       Sin este paso, `motor.publicar` empaqueta ciegamente lo que haya en
       disco, esté o no al día.
    3. `mix meta.export` + `mix motor.export` (de TODOS los catálogos, como
       siempre — solo cambia en disco el archivo del que de verdad se tocó).
    4. Arma un `.tar.gz` con, por cada catálogo en alcance: su schema
       (`lib/.../catalogos/<catalogo>.ex`), sus migraciones
       (`priv/repo/migrations/*<catalogo>*.exs`), su `<catalogo>.meta.json`
       (+ `.motor.json` si tiene autómata propio — un detalle no), y su
       carpeta de reglas de negocio si existe.
    5. Dispara el workflow `.github/workflows/bc-deploy.yml` (GitHub
       Actions) vía `gh workflow run`, mandando el bundle en base64 como
       input — ese workflow extrae el bundle SOBRE un checkout efímero de
       `main`, compila, arma la imagen Docker y la despliega, todo dentro de
       un runner que se destruye al terminar. `origin/main` nunca se entera:
       ni un `git add`, ni un commit, ni un push en ningún paso de acá.

  Requiere `gh` (GitHub CLI) autenticado con acceso al repo — mismo binario
  que ya se usa para administrar el resto del proyecto. Los 3 secrets que
  el workflow necesita (`DEPLOY_HOST`/`DEPLOY_USER`/`DEPLOY_SSH_KEY`) ya
  están configurados desde el primer deploy real del BPB — este task no
  necesita ni ve ninguna credencial de producción, corren enteras del lado
  de GitHub Actions.
  """

  def run([]), do: Mix.raise("Uso: mix motor.publicar <catalogo>")

  def run([catalogo | _resto]) do
    Mix.Task.run("app.config")

    Mix.shell().info("== validando \"#{catalogo}\" ==")
    {header, detalles, catalogos} = validar!(catalogo)

    if detalles != [] do
      Mix.shell().info("  incluye detalle(s): #{Enum.join(Enum.map(detalles, & &1.schema_context_name), ", ")}")
    end

    referenciados = catalogos -- [catalogo | Enum.map(detalles, & &1.schema_context_name)]

    if referenciados != [] do
      Mix.shell().info("  incluye referenciado(s): #{Enum.join(referenciados, ", ")}")
    end

    Mix.shell().info("\n== re-sincronizando schemas contra la metadata actual ==")
    Mix.Task.rerun("gen.catalogos")

    Mix.shell().info("\n== exportando catálogos + autómata ==")
    Mix.Task.rerun("meta.export")
    Mix.Task.rerun("motor.export")

    Mix.shell().info("\n== armando bundle ==")
    bundle_path = armar_bundle(catalogos)
    Mix.shell().info("  #{bundle_path} (#{tamanio_legible(bundle_path)})")

    Mix.shell().info("\n== disparando BC Deploy en GitHub Actions ==")
    disparar_deploy(catalogo, bundle_path, header)
  end

  defp validar!(catalogo) do
    {:ok, resultado, _apps} =
      Ecto.Migrator.with_repo(MetadataApp.Repo, fn _repo ->
        header = MetaSchemaContext.obtener_header_por_nombre(catalogo)
        validacion = MetaEstadosAdmin.validar_motor(catalogo)

        if header do
          detalles = MetaSchemaContext.listar_catalogos_detalle(header.id)
          base = [catalogo | Enum.map(detalles, & &1.schema_context_name)]
          catalogos = expandir_referencias(base, MapSet.new(base))
          {header, validacion, detalles, catalogos}
        else
          {header, validacion, [], []}
        end
      end)

    case resultado do
      {nil, _validacion, _detalles, _catalogos} ->
        Mix.raise("\"#{catalogo}\" no existe.")

      {_header, {:error, motivo}, _detalles, _catalogos} ->
        Mix.raise("#{catalogo}: #{motivo}")

      {header, {:ok, %{problemas: problemas, valido?: valido?}}, detalles, catalogos} ->
        Enum.each(problemas, fn p ->
          etiqueta = if p.severidad == :error, do: "ERROR", else: "advertencia"
          Mix.shell().info("  [#{etiqueta}] #{p.mensaje}")
        end)

        if problemas == [], do: Mix.shell().info("  sin problemas")

        unless valido? do
          Mix.raise("\"#{catalogo}\" no pasa validar_motor — corregí los errores de arriba antes de publicar.")
        end

        {header, detalles, catalogos}
    end
  end

  # Cierre transitivo de dependencias por campo "referencia" — si A
  # referencia a B y B referencia a C, publicar A tiene que arrastrar
  # también a B y C (su migración crea una FK contra una tabla que en
  # producción, si nunca se desplegó nada antes, todavía no existe).
  defp expandir_referencias(pendientes, vistos) do
    nuevos =
      pendientes
      |> Enum.flat_map(&referencias_de/1)
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(vistos, &1))

    case nuevos do
      [] -> MapSet.to_list(vistos)
      _ -> expandir_referencias(nuevos, Enum.reduce(nuevos, vistos, &MapSet.put(&2, &1)))
    end
  end

  defp referencias_de(catalogo) do
    catalogo
    |> MetaSchemaContext.listar_detalles()
    |> Enum.filter(&(&1.schema_context_properties["tipo"] == "referencia"))
    |> Enum.map(& &1.schema_context_properties["catalogo"])
  end

  defp armar_bundle(catalogos) do
    destino = Path.join(System.tmp_dir!(), "bc-bundle-#{System.unique_integer([:positive])}.tar.gz")
    rutas = Enum.flat_map(catalogos, &rutas_de/1)

    if rutas == [] do
      Mix.raise("Ningún archivo encontrado para #{inspect(catalogos)} — ¿ya corriste \"mix gen.catalogos\"?")
    end

    # --force-local: en Windows, tar interpreta "C:\..." como un archivo
    # REMOTO (host "C", mismo formato que "usuario@host:ruta") si no se le
    # dice explícitamente que es local — bug conocido de bsdtar/GNU tar con
    # letras de unidad. Sin esto, "tar" falla con "Cannot connect to C:".
    case System.cmd("tar", ["--force-local", "-czf", destino | rutas], stderr_to_stdout: true) do
      {_salida, 0} -> destino
      {salida, status} -> Mix.raise("tar falló (status #{status}):\n#{salida}")
    end
  end

  defp rutas_de(catalogo) do
    schema = Path.join(["lib", "metadata_app", "meta_business_process", "catalogos", "#{catalogo}.ex"])
    migraciones = Path.wildcard("priv/repo/migrations/*#{catalogo}*.exs")
    meta = "priv/repo/catalogos/#{catalogo}.meta.json"
    motor = "priv/repo/catalogos/#{catalogo}.motor.json"
    reglas = Path.join(["lib", "metadata_app", "meta_business_process", "reglas", catalogo])

    ([schema, meta, motor] ++ migraciones ++ [reglas])
    |> Enum.filter(&File.exists?/1)
  end

  defp tamanio_legible(path) do
    kb = File.stat!(path).size / 1024
    "#{Float.round(kb, 1)} KB"
  end

  # El bundle viaja en base64 como archivo (@ruta), no como argumento de
  # línea de comandos ni por stdin -- un bundle de varios catálogos con
  # varias reglas puede superar el límite práctico de un solo argumento,
  # y System.cmd/3 no tiene forma de pasar stdin. "gh workflow run" lee
  # "-F campo=@archivo" como el CONTENIDO de ese archivo (mismo mecanismo
  # que "gh api", ver "gh help api").
  defp disparar_deploy(catalogo, bundle_path, header) do
    b64_path = bundle_path <> ".b64"
    File.write!(b64_path, Base.encode64(File.read!(bundle_path)))

    args = [
      "workflow",
      "run",
      "bc-deploy.yml",
      "-f",
      "catalogo=#{catalogo}",
      "-F",
      "bundle_b64=@#{b64_path}"
    ]

    resultado = System.cmd("gh", args, stderr_to_stdout: true)
    File.rm(bundle_path)
    File.rm(b64_path)

    case resultado do
      {salida, 0} ->
        Mix.shell().info(salida)

        Mix.shell().info(
          "Disparado — \"#{header.schema_context_label}\" (#{catalogo}) va camino a producción. " <>
            "Seguí el progreso con \"gh run list\" / \"gh run watch\"."
        )

      {salida, status} ->
        Mix.raise("gh workflow run falló (status #{status}):\n#{salida}")
    end
  end
end
