defmodule MetadataApp.PropagacionContext.SeguridadMigracionTest do
  use MetadataApp.DataCase, async: true

  alias MetadataApp.PropagacionContext.SeguridadMigracion, as: SM

  # clasificar/1 es PURO (solo AST, nunca toca una base) -- usamos
  # migraciones REALES del repo como fixtures cuando calzan (mismo
  # criterio del skill spec: verificar contra la realidad, no inventar
  # ejemplos sintéticos cuando ya hay uno real que sirve), y archivos
  # temporales chicos para los casos que no tienen un ejemplo real a mano.

  defp migracion_temporal(contenido) do
    path = Path.join(System.tmp_dir!(), "sm_test_#{System.unique_integer([:positive])}.exs")
    File.write!(path, contenido)
    on_exit_cleanup(path)
    path
  end

  defp on_exit_cleanup(path) do
    ExUnit.Callbacks.on_exit(fn -> File.rm(path) end)
  end

  describe "clasificar/1 -- tabla nueva (fixture real)" do
    test "create table + create index -- automática, candidatas correctas" do
      ruta = "priv/repo/migrations/20260804203016_crear_meta_schema_notificacion.exs"
      assert {:automatico, operaciones} = SM.clasificar(ruta)

      assert %{tipo: :tabla_nueva, tabla: :meta_schema_notificacion} in operaciones
      assert %{tipo: :indice} in operaciones
    end
  end

  describe "clasificar/1 -- columna nueva + índice (fixture real)" do
    test "alter table (2 add) + create unique_index -- automática, candidatas correctas" do
      ruta = "priv/repo/migrations/20260721210000_agregar_trn_a_meta_schema_header.exs"
      assert {:automatico, operaciones} = SM.clasificar(ruta)

      assert %{tipo: :columna_nueva, tabla: :meta_schema_header, campo: :schema_es_transaccional, default: false} in operaciones
      assert %{tipo: :columna_nueva, tabla: :meta_schema_header, campo: :codigo_trn, default: nil} in operaciones
      assert %{tipo: :indice} in operaciones
    end
  end

  describe "clasificar/1 -- manual, siempre" do
    test "remove -- manual, con el texto literal de la operación" do
      ruta =
        migracion_temporal("""
        defmodule Test.Remove do
          use Ecto.Migration
          def change do
            alter table(:foo) do
              remove :bar
            end
          end
        end
        """)

      assert {:manual, motivo, %{tipo: :remove}} = SM.clasificar(ruta)
      assert motivo =~ "remove"
      assert motivo =~ "bar"
    end

    test "drop table -- manual" do
      ruta =
        migracion_temporal("""
        defmodule Test.DropTable do
          use Ecto.Migration
          def change do
            drop table(:foo)
          end
        end
        """)

      assert {:manual, motivo, %{tipo: :drop_table, tabla: :foo}} = SM.clasificar(ruta)
      assert motivo =~ "drop table"
    end

    test "modify -- manual" do
      ruta =
        migracion_temporal("""
        defmodule Test.Modify do
          use Ecto.Migration
          def change do
            alter table(:foo) do
              modify :bar, :integer
            end
          end
        end
        """)

      assert {:manual, motivo, %{tipo: :modify}} = SM.clasificar(ruta)
      assert motivo =~ "modify"
    end

    test "execute -- manual, con \"SQL crudo\" explícito en el motivo" do
      ruta =
        migracion_temporal("""
        defmodule Test.Execute do
          use Ecto.Migration
          def change do
            execute "UPDATE foo SET bar = 1"
          end
        end
        """)

      assert {:manual, motivo, %{tipo: :no_reconocido}} = SM.clasificar(ruta)
      assert motivo =~ "SQL crudo"
    end

    test "una sola operación manual entre varias vuelve TODA la migración manual" do
      ruta =
        migracion_temporal("""
        defmodule Test.Mixta do
          use Ecto.Migration
          def change do
            create table(:foo) do
              add :a, :string
            end

            alter table(:bar) do
              add :b, :string
              remove :c
            end
          end
        end
        """)

      assert {:manual, _motivo, _bloqueante} = SM.clasificar(ruta)
    end

    test "construcción no reconocida -- manual por default, nunca automática ante ambigüedad" do
      ruta =
        migracion_temporal("""
        defmodule Test.NoReconocido do
          use Ecto.Migration
          def change do
            algo_que_no_es_del_dsl(:foo, :bar)
          end
        end
        """)

      assert {:manual, _motivo, %{tipo: :no_reconocido}} = SM.clasificar(ruta)
    end

    test "up/down explícitos (sin change/0) -- manual por default" do
      ruta =
        migracion_temporal("""
        defmodule Test.UpDown do
          use Ecto.Migration
          def up, do: execute("SELECT 1")
          def down, do: execute("SELECT 1")
        end
        """)

      assert {:manual, motivo, %{tipo: :sin_change}} = SM.clasificar(ruta)
      assert motivo =~ "up/down"
    end
  end

  describe "verificar_vacio?/2 y verificar_columna_sin_uso?/4 -- EN VIVO contra Postgres real (sandbox de test)" do
    setup do
      Ecto.Adapters.SQL.query!(MetadataApp.Repo, "CREATE TEMP TABLE sm_test_tabla (id serial primary key, campo text)", [])
      :ok
    end

    test "tabla vacía -- true" do
      assert SM.verificar_vacio?("sm_test_tabla", MetadataApp.Repo)
    end

    test "tabla con filas -- false" do
      Ecto.Adapters.SQL.query!(MetadataApp.Repo, "INSERT INTO sm_test_tabla (campo) VALUES ('x')", [])
      refute SM.verificar_vacio?("sm_test_tabla", MetadataApp.Repo)
    end

    test "columna toda NULL, sin default -- sin uso (true)" do
      Ecto.Adapters.SQL.query!(MetadataApp.Repo, "INSERT INTO sm_test_tabla (campo) VALUES (NULL)", [])
      assert SM.verificar_columna_sin_uso?("sm_test_tabla", "campo", nil, MetadataApp.Repo)
    end

    test "columna con UN valor real, sin default -- CON uso (false)" do
      Ecto.Adapters.SQL.query!(MetadataApp.Repo, "INSERT INTO sm_test_tabla (campo) VALUES ('dato real')", [])
      refute SM.verificar_columna_sin_uso?("sm_test_tabla", "campo", nil, MetadataApp.Repo)
    end

    test "columna toda en su default -- sin uso (true)" do
      Ecto.Adapters.SQL.query!(MetadataApp.Repo, "INSERT INTO sm_test_tabla (campo) VALUES ('default_x')", [])
      assert SM.verificar_columna_sin_uso?("sm_test_tabla", "campo", "default_x", MetadataApp.Repo)
    end

    test "columna con un valor DISTINTO del default -- CON uso (false)" do
      Ecto.Adapters.SQL.query!(MetadataApp.Repo, "INSERT INTO sm_test_tabla (campo) VALUES ('otra_cosa')", [])
      refute SM.verificar_columna_sin_uso?("sm_test_tabla", "campo", "default_x", MetadataApp.Repo)
    end
  end

  describe "clasificar_conjunto/2 (Grupo H)" do
    test "conjunto vacío -- automático, sin operaciones" do
      assert {:automatico, []} = SM.clasificar_conjunto([], MetadataApp.Repo)
    end

    test "todas automáticas a nivel AST (tabla real vacía) -- automático" do
      ruta = "priv/repo/migrations/20260807003316_crear_meta_schema_credencial.exs"
      # tabla real, pero vacía en este sandbox de test (nunca se insertó
      # nada ahí en este test) -- confirma que también pasa el paso 4.
      assert {:automatico, _operaciones} = SM.clasificar_conjunto([ruta], MetadataApp.Repo)
    end

    test "una sola manual entre varias (a nivel AST) -- todo el conjunto manual, corto-circuito ANTES de tocar la base" do
      ruta_automatica = "priv/repo/migrations/20260807003316_crear_meta_schema_credencial.exs"

      ruta_manual =
        migracion_temporal("""
        defmodule Test.ConjuntoManual do
          use Ecto.Migration
          def change do
            drop table(:foo)
          end
        end
        """)

      assert {:manual, motivo, %{tipo: :drop_table}} = SM.clasificar_conjunto([ruta_automatica, ruta_manual], MetadataApp.Repo)
      assert motivo =~ "drop table"
    end

    test "automática a nivel AST, pero la tabla real ya tiene filas -- manual en la verificación en vivo, con el conteo" do
      Ecto.Adapters.SQL.query!(MetadataApp.Repo, "CREATE TEMP TABLE sm_conjunto_con_filas (id serial primary key)", [])
      Ecto.Adapters.SQL.query!(MetadataApp.Repo, "INSERT INTO sm_conjunto_con_filas DEFAULT VALUES", [])

      ruta =
        migracion_temporal("""
        defmodule Test.TablaConFilas do
          use Ecto.Migration
          def change do
            create table(:sm_conjunto_con_filas) do
            end
          end
        end
        """)

      assert {:manual, motivo, %{tipo: :tabla_nueva, filas: 1}} = SM.clasificar_conjunto([ruta], MetadataApp.Repo)
      assert motivo =~ "1 fila(s)"
    end
  end

  describe "version_de/1" do
    test "extrae el prefijo numérico del nombre de archivo" do
      assert SM.version_de("priv/repo/migrations/20260807003316_crear_meta_schema_credencial.exs") == 20_260_807_003_316
    end
  end
end
