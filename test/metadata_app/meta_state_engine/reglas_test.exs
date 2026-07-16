defmodule MetadataApp.MetaStateEngine.ReglasTest.Relacionado do
  use Ecto.Schema

  schema "test_fixture_relacionado" do
    field :nombre, :string
    field :orden, :integer
  end
end

defmodule MetadataApp.MetaStateEngine.ReglasTest do
  use MetadataApp.DataCase, async: true

  import ExUnit.CaptureLog

  alias MetadataApp.MetaStateEngine.Reglas.{Pre, Post}
  alias MetadataApp.MetaBusinessProcess.Catalogos.PtyClientes
  alias MetadataApp.MetaStateEngine.ReglasTest.Relacionado

  defp guid, do: Ecto.UUID.generate() |> String.replace("-", "")
  defp unique, do: System.unique_integer([:positive])

  defp fixture_cliente(attrs \\ %{}) do
    base = %{
      pty_clientes_nombre: "cliente #{unique()}",
      pty_clientes_edad: 30,
      pty_clientes_venta: Decimal.new("100.00")
    }

    base
    |> Map.merge(attrs)
    |> then(&PtyClientes.changeset(%PtyClientes{}, &1))
    |> put_change(:insert_guid, guid())
    |> Repo.insert!()
  end

  defp fixture_relacionado(attrs) do
    base = %{nombre: "relacionado #{unique()}", orden: 0}

    base
    |> Map.merge(attrs)
    |> then(&Ecto.Changeset.cast(%Relacionado{}, &1, [:nombre, :orden]))
    |> Repo.insert!()
  end

  describe "Pre.evaluar/4 — campos_requeridos" do
    test ":ok cuando todos los campos pedidos están completos" do
      cliente = fixture_cliente(%{pty_clientes_nombre: "Ana"})

      assert Pre.evaluar("campos_requeridos", cliente, %{}, %{"campos" => ["pty_clientes_nombre"]}) ==
               :ok
    end

    test "{:error, ...} listando los campos faltantes, sin cortocircuito" do
      # Los campos "de negocio" son null: false (no se puede persistir uno
      # vacío), así que se usa estado_id -- nullable, queda nil si no se
      # setea -- para probar el caso de campo faltante sin violar esa
      # restricción.
      cliente = fixture_cliente()

      assert Pre.evaluar("campos_requeridos", cliente, %{}, %{
               "campos" => ["pty_clientes_nombre", "estado_id"]
             }) == {:error, "faltan completar: estado_id"}
    end
  end

  describe "Pre.evaluar/4 — campo_cumple" do
    test "compara enteros" do
      cliente = fixture_cliente(%{pty_clientes_edad: 30})

      assert Pre.evaluar("campo_cumple", cliente, %{}, %{
               "campo" => "pty_clientes_edad",
               "operador" => ">",
               "valor" => 18
             }) == :ok

      assert {:error, _} =
               Pre.evaluar("campo_cumple", cliente, %{}, %{
                 "campo" => "pty_clientes_edad",
                 "operador" => "<",
                 "valor" => 18
               })
    end

    test "compara Decimal correctamente (no como struct)" do
      cliente = fixture_cliente(%{pty_clientes_venta: Decimal.new("100.50")})

      assert Pre.evaluar("campo_cumple", cliente, %{}, %{
               "campo" => "pty_clientes_venta",
               "operador" => ">=",
               "valor" => 100
             }) == :ok

      assert {:error, _} =
               Pre.evaluar("campo_cumple", cliente, %{}, %{
                 "campo" => "pty_clientes_venta",
                 "operador" => ">",
                 "valor" => 1000
               })
    end
  end

  describe "Pre.evaluar/4 — sin_relacionados" do
    test ":ok cuando no hay filas relacionadas" do
      cliente = fixture_cliente()

      assert Pre.evaluar("sin_relacionados", cliente, %{}, %{
               "entidad" => "test_fixture_relacionado",
               "campo_relacion" => "orden"
             }) == :ok
    end

    test "{:error, ...} cuando hay filas relacionadas" do
      cliente = fixture_cliente()
      fixture_relacionado(%{orden: cliente.id})

      assert {:error, mensaje} =
               Pre.evaluar("sin_relacionados", cliente, %{}, %{
                 "entidad" => "test_fixture_relacionado",
                 "campo_relacion" => "orden"
               })

      assert mensaje =~ "1 registro"
    end

    test "respeta el filtro adicional" do
      cliente = fixture_cliente()
      fixture_relacionado(%{orden: cliente.id, nombre: "no cuenta"})

      assert Pre.evaluar("sin_relacionados", cliente, %{}, %{
               "entidad" => "test_fixture_relacionado",
               "campo_relacion" => "orden",
               "filtro" => %{"campo" => "nombre", "valor" => "sí cuenta"}
             }) == :ok
    end
  end

  describe "Pre.evaluar/4 — requiere_rol" do
    test ":ok cuando el contexto trae el rol exacto" do
      assert Pre.evaluar("requiere_rol", %{}, %{"rol" => "supervisor"}, %{"rol" => "supervisor"}) ==
               :ok
    end

    test ":ok cuando el rol está en la lista de roles" do
      assert Pre.evaluar("requiere_rol", %{}, %{"roles" => ["vendedor", "supervisor"]}, %{
               "rol" => "supervisor"
             }) == :ok
    end

    test "{:error, ...} cuando falta el rol" do
      assert {:error, _} =
               Pre.evaluar("requiere_rol", %{}, %{"rol" => "vendedor"}, %{"rol" => "supervisor"})
    end
  end

  describe "Pre.evaluar/4 — dato_en_contexto" do
    test ":ok cuando el dato está presente y no vacío" do
      assert Pre.evaluar("dato_en_contexto", %{}, %{"motivo_baja" => "cierre"}, %{
               "dato" => "motivo_baja"
             }) == :ok
    end

    test "{:error, ...} cuando falta o está vacío" do
      assert {:error, _} = Pre.evaluar("dato_en_contexto", %{}, %{}, %{"dato" => "motivo_baja"})

      assert {:error, _} =
               Pre.evaluar("dato_en_contexto", %{}, %{"motivo_baja" => ""}, %{
                 "dato" => "motivo_baja"
               })
    end
  end

  describe "Post.resolver_valor/1 (puro)" do
    test "\"ahora\" resuelve a la fecha de hoy" do
      assert Post.resolver_valor("ahora") == Date.utc_today()
    end

    test "cualquier otro valor pasa igual, incluyendo nil" do
      assert Post.resolver_valor(nil) == nil
      assert Post.resolver_valor("literal") == "literal"
      assert Post.resolver_valor(42) == 42
    end
  end

  describe "Post.ejecutar/5 — estampar_valor" do
    test "escribe un literal en el campo del registro" do
      cliente = fixture_cliente(%{pty_clientes_edad: 10})

      assert {:ok, %{"pty_clientes_edad" => 99}} =
               Post.ejecutar(
                 "estampar_valor",
                 cliente,
                 %{},
                 %{"campo" => "pty_clientes_edad", "valor" => 99},
                 Repo
               )

      assert Repo.get!(PtyClientes, cliente.id).pty_clientes_edad == 99
    end

    test "limpia el campo con null" do
      # Los campos "de negocio" son null: false -- no hay ninguno donde
      # limpiar con null sea válido hoy (ej. fecha_baja del spec ni existe
      # todavía). delete_guid es nullable y sirve para probar el mecanismo:
      # primero se estampa un valor real, después se limpia con nil.
      cliente = fixture_cliente()

      assert {:ok, _} =
               Post.ejecutar(
                 "estampar_valor",
                 cliente,
                 %{},
                 %{"campo" => "delete_guid", "valor" => "temporal"},
                 Repo
               )

      assert Repo.get!(PtyClientes, cliente.id).delete_guid == "temporal"

      assert {:ok, _} =
               Post.ejecutar(
                 "estampar_valor",
                 cliente,
                 %{},
                 %{"campo" => "delete_guid", "valor" => nil},
                 Repo
               )

      assert Repo.get!(PtyClientes, cliente.id).delete_guid == nil
    end
  end

  describe "Post.ejecutar/5 — mutar_relacionados" do
    test "actualiza todas las filas relacionadas" do
      cliente = fixture_cliente()
      relacionado1 = fixture_relacionado(%{orden: cliente.id})
      relacionado2 = fixture_relacionado(%{orden: cliente.id})
      _otro = fixture_relacionado(%{orden: cliente.id + 999_999})

      assert {:ok, %{filas: 2}} =
               Post.ejecutar(
                 "mutar_relacionados",
                 cliente,
                 %{},
                 %{
                   "entidad" => "test_fixture_relacionado",
                   "campo_relacion" => "orden",
                   "cambio" => %{"campo" => "orden", "valor" => 0}
                 },
                 Repo
               )

      assert Repo.get!(Relacionado, relacionado1.id).orden == 0
      assert Repo.get!(Relacionado, relacionado2.id).orden == 0
    end
  end

  describe "Post.ejecutar/5 — notificar" do
    test "no falla y loguea el intento (placeholder, sin pipeline real todavía)" do
      cliente = fixture_cliente()
      # config/test.exs sube el nivel global a :warning; hay que bajarlo acá
      # para que este :info puntual llegue siquiera al handler de captura.
      nivel_previo = Logger.level()
      Logger.configure(level: :info)

      log =
        capture_log(fn ->
          assert {:ok, %{destinatario: "vendedor_asignado", plantilla: "baja_cliente"}} =
                   Post.ejecutar(
                     "notificar",
                     cliente,
                     %{},
                     %{"destinatario" => "vendedor_asignado", "plantilla" => "baja_cliente"},
                     Repo
                   )
        end)

      Logger.configure(level: nivel_previo)
      assert log =~ "notificar (placeholder)"
    end
  end
end
