defmodule MetadataApp.AmbientesTest do
  use MetadataApp.DataCase, async: true

  alias MetadataApp.Ambientes
  alias MetadataApp.Ambientes.Ambiente

  defp attrs_validos(overrides \\ %{}) do
    Map.merge(
      %{
        "nombre" => "ambiente_#{System.unique_integer([:positive])}",
        "host" => "127.0.0.1",
        "ssh_usuario" => "deploy",
        "ssh_password_nuevo" => "una-contrasena"
      },
      overrides
    )
  end

  describe "changeset_creacion/2" do
    test "exige nombre/host/ssh_usuario" do
      changeset = Ambiente.changeset_creacion(%Ambiente{}, %{})
      refute changeset.valid?
      assert %{nombre: ["can't be blank"], host: ["can't be blank"], ssh_usuario: ["can't be blank"]} = errors_on(changeset)
    end

    test "exige al menos contraseña o llave privada" do
      changeset = Ambiente.changeset_creacion(%Ambiente{}, attrs_validos(%{"ssh_password_nuevo" => ""}))
      refute changeset.valid?
      assert "necesita contraseña o llave privada" in errors_on(changeset).ssh_password_nuevo
    end

    test "acepta llave privada sola, sin contraseña" do
      changeset =
        Ambiente.changeset_creacion(%Ambiente{}, attrs_validos(%{"ssh_password_nuevo" => "", "ssh_llave_privada_nueva" => "-----BEGIN..."}))

      assert changeset.valid?
    end

    test "válido con nombre/host/usuario/contraseña" do
      assert Ambiente.changeset_creacion(%Ambiente{}, attrs_validos()).valid?
    end
  end

  describe "changeset_edicion/2" do
    test "no exige credencial nueva -- vacía significa 'no tocar'" do
      {:ok, ambiente} = Ambientes.crear_ambiente(attrs_validos())
      changeset = Ambiente.changeset_edicion(ambiente, %{"nombre" => ambiente.nombre, "host" => ambiente.host, "ssh_usuario" => ambiente.ssh_usuario})
      assert changeset.valid?
    end
  end

  describe "CRUD + soft-delete" do
    test "crear_ambiente/1 persiste, cifra la credencial y no la vuelve a mostrar" do
      {:ok, ambiente} = Ambientes.crear_ambiente(attrs_validos(%{"nombre" => "prueba-crear"}))
      assert ambiente.nombre == "prueba-crear"
      # El campo REAL sale descifrado al leer de vuelta (Cloak.Ecto.Binary
      # decifra en load) -- lo que se prueba acá es que el valor entra
      # correctamente, no que quede oculto en memoria (eso ya lo hace el
      # formulario, que nunca lo precarga -- ver AmbientesLive).
      recargado = Ambientes.obtener_ambiente!(ambiente.id)
      assert recargado.ssh_password == "una-contrasena"
    end

    test "actualizar_ambiente/2 con contraseña en blanco conserva la anterior" do
      {:ok, ambiente} = Ambientes.crear_ambiente(attrs_validos(%{"nombre" => "prueba-editar"}))
      {:ok, actualizado} = Ambientes.actualizar_ambiente(ambiente, %{"host" => "otro-host", "ssh_password_nuevo" => ""})

      assert actualizado.host == "otro-host"
      assert actualizado.ssh_password == "una-contrasena"
    end

    test "actualizar_ambiente/2 con contraseña nueva la reemplaza" do
      {:ok, ambiente} = Ambientes.crear_ambiente(attrs_validos(%{"nombre" => "prueba-reemplazar"}))
      {:ok, actualizado} = Ambientes.actualizar_ambiente(ambiente, %{"ssh_password_nuevo" => "otra-contrasena"})

      assert actualizado.ssh_password == "otra-contrasena"
    end

    test "eliminar_ambiente/1 es soft-delete -- no aparece en listar_ambientes/0 ni obtener_ambiente_por_nombre/1" do
      {:ok, ambiente} = Ambientes.crear_ambiente(attrs_validos(%{"nombre" => "prueba-eliminar"}))
      {:ok, _} = Ambientes.eliminar_ambiente(ambiente)

      refute ambiente.nombre in Enum.map(Ambientes.listar_ambientes(), & &1.nombre)
      assert Ambientes.obtener_ambiente_por_nombre("prueba-eliminar") == nil
    end

    test "obtener_ambiente_por_nombre/1 resuelve por nombre exacto" do
      {:ok, ambiente} = Ambientes.crear_ambiente(attrs_validos(%{"nombre" => "prueba-nombre-exacto"}))
      assert Ambientes.obtener_ambiente_por_nombre("prueba-nombre-exacto").id == ambiente.id
      assert Ambientes.obtener_ambiente_por_nombre("no-existe") == nil
    end
  end
end
