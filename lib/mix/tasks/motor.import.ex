defmodule Mix.Tasks.Motor.Import do
  use Mix.Task
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.MetaEstadosAdmin

  @shortdoc "Importa el autómata (estados/transiciones/reglas) desde priv/repo/catalogos/*.motor.json"

  @moduledoc """
  Uso: mix motor.import [directorio_entrada]

  Default: priv/repo/catalogos/

  Recrea estados/transiciones/reglas leyendo cada `*.motor.json` del
  directorio (uno por catálogo, ver `mix motor.export`), resolviendo toda
  referencia por NOMBRE, no por id (mismo motivo que `mix motor.export`).
  Idempotente: lo que ya existe (mismo nombre de estado; misma
  acción+origen+destino de transición; misma tipo+regla dentro de una
  transición) se deja sin tocar, no se duplica ni se actualiza.

  Requiere que el catálogo ya exista — correr después de `mix meta.import`
  + `mix gen.catalogos`, nunca antes (mismo orden que ya exige el resto del
  pipeline de reproducibilidad).
  """

  def run(args) do
    Mix.Task.run("app.config")

    dir = List.first(args) || "priv/repo/catalogos"
    unless File.dir?(dir), do: Mix.raise("No existe el directorio #{dir}")

    catalogos =
      dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".motor.json"))
      |> Enum.sort()
      |> Enum.map(&(dir |> Path.join(&1) |> File.read!() |> Jason.decode!()))

    {:ok, _resultado, _apps} =
      Ecto.Migrator.with_repo(MetadataApp.Repo, fn _repo ->
        Enum.each(catalogos, &importar_catalogo/1)
      end)
  end

  defp importar_catalogo(%{"catalogo" => nombre} = datos) do
    case MetaSchemaContext.obtener_header_por_nombre(nombre) do
      nil ->
        Mix.shell().error(
          "- #{nombre}: catálogo no encontrado, saltado (¿faltó \"mix meta.import\" + \"mix gen.catalogos\" antes?)"
        )

      header ->
        estados_por_nombre = importar_estados(header, datos["estados"] || [])
        importar_transiciones(header, datos["transiciones"] || [], estados_por_nombre)
    end
  end

  defp importar_estados(header, lista) do
    existentes = header.id |> MetaEstadosAdmin.listar_estados() |> Map.new(&{&1.nombre, &1})

    Enum.reduce(lista, existentes, fn attrs, acc ->
      nombre = attrs["nombre"]

      if Map.has_key?(acc, nombre) do
        Mix.shell().info("= #{header.schema_context_name} estado \"#{nombre}\": ya existía")
        acc
      else
        atributos = %{
          "meta_schema_header_id" => header.id,
          "nombre" => nombre,
          "orden" => attrs["orden"],
          "es_inicial" => attrs["es_inicial"] || false,
          "color" => attrs["color"],
          "icono" => attrs["icono"],
          "empresa_id" => attrs["empresa_id"]
        }

        case MetaEstadosAdmin.crear_estado(atributos) do
          {:ok, estado} ->
            Mix.shell().info("+ #{header.schema_context_name} estado \"#{nombre}\": creado")
            Map.put(acc, nombre, estado)

          {:error, changeset} ->
            Mix.raise("Error importando estado \"#{nombre}\" de #{header.schema_context_name}: #{inspect(changeset.errors)}")
        end
      end
    end)
  end

  defp importar_transiciones(header, lista, estados_por_nombre) do
    Enum.reduce(lista, MetaEstadosAdmin.listar_transiciones(header.id), fn attrs, acc ->
      origen_id = resolver_estado_id(attrs["estado_origen"], estados_por_nombre)
      destino_id = resolver_estado_id(attrs["estado_destino"], estados_por_nombre)

      case Enum.find(acc, &(&1.accion == attrs["accion"] and &1.estado_origen_id == origen_id)) do
        nil ->
          crear_transicion_e_importar_reglas(header, attrs, origen_id, destino_id, acc)

        transicion ->
          Mix.shell().info("= #{header.schema_context_name} transición \"#{attrs["accion"]}\": ya existía")
          importar_reglas(header, transicion, attrs["reglas"] || [])
          acc
      end
    end)
  end

  defp crear_transicion_e_importar_reglas(header, attrs, origen_id, destino_id, acumulado) do
    atributos = %{
      "meta_schema_header_id" => header.id,
      "accion" => attrs["accion"],
      "etiqueta" => attrs["etiqueta"],
      "estado_origen_id" => origen_id,
      "estado_destino_id" => destino_id,
      "empresa_id" => attrs["empresa_id"]
    }

    case MetaEstadosAdmin.crear_transicion(atributos) do
      {:ok, transicion} ->
        Mix.shell().info("+ #{header.schema_context_name} transición \"#{attrs["accion"]}\": creada")
        importar_reglas(header, transicion, attrs["reglas"] || [])
        [transicion | acumulado]

      {:error, changeset} ->
        Mix.raise(
          "Error importando transición \"#{attrs["accion"]}\" de #{header.schema_context_name}: #{inspect(changeset.errors)}"
        )
    end
  end

  defp resolver_estado_id(nil, _estados_por_nombre), do: nil

  defp resolver_estado_id(nombre, estados_por_nombre) do
    case Map.fetch(estados_por_nombre, nombre) do
      {:ok, estado} -> estado.id
      :error -> Mix.raise("Estado \"#{nombre}\" no encontrado — ¿faltó en la lista de estados del JSON?")
    end
  end

  defp importar_reglas(header, transicion, lista) do
    existentes = transicion.id |> MetaEstadosAdmin.listar_reglas() |> MapSet.new(&{&1.tipo, &1.regla})

    Enum.each(lista, fn attrs ->
      clave = {attrs["tipo"], attrs["regla"]}

      if MapSet.member?(existentes, clave) do
        Mix.shell().info(
          "= #{header.schema_context_name} transición \"#{transicion.accion}\" regla \"#{attrs["regla"]}\" (#{attrs["tipo"]}): ya existía"
        )
      else
        atributos = %{
          "transicion_id" => transicion.id,
          "tipo" => attrs["tipo"],
          "regla" => attrs["regla"],
          "params" => attrs["params"] || %{},
          "orden" => attrs["orden"] || 0,
          "transaccional" => Map.get(attrs, "transaccional", true)
        }

        case MetaEstadosAdmin.crear_regla(atributos) do
          {:ok, _regla} ->
            Mix.shell().info(
              "+ #{header.schema_context_name} transición \"#{transicion.accion}\" regla \"#{attrs["regla"]}\" (#{attrs["tipo"]}): creada"
            )

          {:error, changeset} ->
            Mix.raise(
              "Error importando regla \"#{attrs["regla"]}\" de #{header.schema_context_name}/#{transicion.accion}: #{inspect(changeset.errors)}"
            )
        end
      end
    end)
  end
end
