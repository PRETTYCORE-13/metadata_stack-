# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Motor de Estados y Transiciones — demo de punta a punta sobre "clientes"
# (spec sección 8.6): Nuevo -> Prospecto -> Activo -> Baja -> (reactivación:
# Baja -> Activo). Seguro de re-correr (cada paso chequea si ya existe).
#
# "pedidos" y "rutas" del ejemplo del spec no existen como catálogos reales
# en este proyecto — se usan pty_canal/pty_subcanal como relación ilustrativa
# (mismo mecanismo, entidad de mentira) solo para poder mostrar
# sin_relacionados/mutar_relacionados funcionando de verdad contra Postgres.

alias MetadataApp.Repo
alias MetadataApp.BusinessProcessBuilder.MetaSchema.{Header, Detail}
alias MetadataApp.MetaSchema.{Estado, Transicion, TransicionRegla}
alias MetadataApp.BusinessProcessBuilder.CatalogoGenerador

guid = fn -> Ecto.UUID.generate() |> String.replace("-", "") end

header = Repo.get_by!(Header, schema_context_name: "pty_clientes")

# --- 0. Campo fecha_baja real, agregado vía el propio Motor BC -------------
# (meta_schema_detail + CatalogoGenerador.generar/1 -- ALTER TABLE real +
# schema regenerado, no un campo de mentira).
unless Repo.get_by(Detail,
         meta_schema_header_id: header.id,
         schema_context_field: "pty_clientes_fecha_baja"
       ) do
  %Detail{}
  |> Detail.changeset(%{
    meta_schema_header_id: header.id,
    schema_context_field: "pty_clientes_fecha_baja",
    schema_context_properties: %{
      "etiqueta" => "Fecha de baja",
      "tipo" => "date",
      "orden" => 4,
      "visible" => true,
      "editable" => true,
      # Un cliente nace sin fecha_baja -- solo la escribe StateEngine al dar
      # de baja (estampar_valor), nunca es obligatoria al crear.
      "opcional" => true
    }
  })
  |> Ecto.Changeset.put_change(:insert_guid, guid.())
  |> Repo.insert!()

  {:ok, _} = CatalogoGenerador.generar("pty_clientes")
  Mix.shell().info("+ pty_clientes_fecha_baja: campo agregado")
else
  Mix.shell().info("= pty_clientes_fecha_baja: ya existía")
end

# --- 1. Estados --------------------------------------------------------

ensure_estado = fn nombre, orden, es_inicial ->
  case Repo.get_by(Estado, meta_schema_header_id: header.id, nombre: nombre) do
    nil ->
      estado =
        %Estado{}
        |> Estado.changeset(%{
          meta_schema_header_id: header.id,
          nombre: nombre,
          orden: orden,
          es_inicial: es_inicial
        })
        |> Ecto.Changeset.put_change(:insert_guid, guid.())
        |> Repo.insert!()

      Mix.shell().info("+ estado #{nombre}: creado")
      estado

    estado ->
      Mix.shell().info("= estado #{nombre}: ya existía")
      estado
  end
end

nuevo = ensure_estado.("Nuevo", 1, true)
prospecto = ensure_estado.("Prospecto", 2, false)
activo = ensure_estado.("Activo", 3, false)
baja = ensure_estado.("Baja", 4, false)

# --- 2. Transiciones + reglas --------------------------------------------

ensure_transicion = fn accion, etiqueta, origen, destino, reglas ->
  case Repo.get_by(Transicion,
         meta_schema_header_id: header.id,
         estado_origen_id: origen.id,
         accion: accion
       ) do
    nil ->
      transicion =
        %Transicion{}
        |> Transicion.changeset(%{
          meta_schema_header_id: header.id,
          accion: accion,
          etiqueta: etiqueta,
          estado_origen_id: origen.id,
          estado_destino_id: destino.id
        })
        |> Ecto.Changeset.put_change(:insert_guid, guid.())
        |> Repo.insert!()

      Enum.each(reglas, fn attrs ->
        %TransicionRegla{}
        |> TransicionRegla.changeset(Map.put(attrs, :transicion_id, transicion.id))
        |> Ecto.Changeset.put_change(:insert_guid, guid.())
        |> Repo.insert!()
      end)

      Mix.shell().info("+ transición #{origen.nombre} -> #{destino.nombre} (#{accion}): creada")
      transicion

    transicion ->
      Mix.shell().info(
        "= transición #{origen.nombre} -> #{destino.nombre} (#{accion}): ya existía"
      )

      transicion
  end
end

# Nuevo -> Prospecto: sin reglas, el spec no detalla ninguna para este paso.
ensure_transicion.("calificar", "Calificar como prospecto", nuevo, prospecto, [])

# Prospecto -> Activo: requiere datos fiscales completos.
# (pty_clientes no tiene campos fiscales reales -- pty_clientes_nombre se usa
# como sustituto ilustrativo de "datos fiscales completos".)
ensure_transicion.("activar", "Activar", prospecto, activo, [
  %{
    tipo: "pre",
    regla: "campos_requeridos",
    params: %{"campos" => ["pty_clientes_nombre"]},
    orden: 1
  }
])

# Activo -> Baja: sin pedidos abiertos (pty_canal como entidad ilustrativa) +
# motivo de baja capturado. Post: estampa fecha_baja, desasigna "rutas"
# (pty_subcanal como entidad ilustrativa) y notifica al vendedor.
ensure_transicion.("dar_de_baja", "Dar de baja", activo, baja, [
  %{
    tipo: "pre",
    regla: "sin_relacionados",
    params: %{"entidad" => "pty_canal", "campo_relacion" => "canal_orden"},
    orden: 1
  },
  %{tipo: "pre", regla: "dato_en_contexto", params: %{"dato" => "motivo_baja"}, orden: 2},
  %{
    tipo: "post",
    regla: "estampar_valor",
    params: %{"campo" => "pty_clientes_fecha_baja", "valor" => "ahora"},
    transaccional: true,
    orden: 1
  },
  %{
    tipo: "post",
    regla: "mutar_relacionados",
    params: %{
      "entidad" => "pty_subcanal",
      "campo_relacion" => "id_canal",
      "cambio" => %{"campo" => "id_canal", "valor" => nil}
    },
    transaccional: true,
    orden: 2
  },
  %{
    tipo: "post",
    regla: "notificar",
    params: %{"destinatario" => "vendedor_asignado", "plantilla" => "baja_cliente"},
    transaccional: false,
    orden: 3
  }
])

# Baja -> Activo (reactivación): solo un supervisor puede reactivar. Post:
# limpia fecha_baja y notifica.
ensure_transicion.("reactivar", "Reactivar", baja, activo, [
  %{tipo: "pre", regla: "requiere_rol", params: %{"rol" => "supervisor"}, orden: 1},
  %{
    tipo: "post",
    regla: "estampar_valor",
    params: %{"campo" => "pty_clientes_fecha_baja", "valor" => nil},
    transaccional: true,
    orden: 1
  },
  %{
    tipo: "post",
    regla: "notificar",
    params: %{"destinatario" => "vendedor_asignado", "plantilla" => "cliente_reactivado"},
    transaccional: false,
    orden: 2
  }
])
