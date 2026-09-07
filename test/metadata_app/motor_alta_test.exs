defmodule MetadataApp.MotorAltaTest do
  use ExUnit.Case, async: true

  alias MetadataApp.MotorAlta

  describe "charset_valido?/1" do
    test "acepta minúsculas, dígitos y guiones internos" do
      assert MotorAlta.charset_valido?("crm")
      assert MotorAlta.charset_valido?("direem-2")
      assert MotorAlta.charset_valido?("unstable")
    end

    test "rechaza mayúsculas, guión bajo, espacios y símbolos" do
      refute MotorAlta.charset_valido?("CRM")
      refute MotorAlta.charset_valido?("direm_2")
      refute MotorAlta.charset_valido?("mi sistema")
      refute MotorAlta.charset_valido?("cliente.nuevo")
    end

    test "rechaza empezar o terminar en guión" do
      refute MotorAlta.charset_valido?("-crm")
      refute MotorAlta.charset_valido?("crm-")
    end

    test "rechaza vacío y más de 63 caracteres" do
      refute MotorAlta.charset_valido?("")
      refute MotorAlta.charset_valido?(String.duplicate("a", 64))
      assert MotorAlta.charset_valido?(String.duplicate("a", 63))
    end
  end

  describe "sistema_registrado?/2 y validar_nombre/2 contra un archivo temporal" do
    setup do
      path = Path.join(System.tmp_dir!(), "sistemas_test_#{System.unique_integer([:positive])}.json")
      on_exit(fn -> File.rm(path) end)
      {:ok, path: path}
    end

    test "archivo inexistente se trata como {} -- ningún sistema registrado", %{path: path} do
      refute MotorAlta.sistema_registrado?("crm", path)
      assert {:ok, "crm"} = MotorAlta.validar_nombre("crm", path)
    end

    test "archivo vacío ({}) -- ningún sistema registrado", %{path: path} do
      File.write!(path, "{}")
      refute MotorAlta.sistema_registrado?("crm", path)
    end

    test "detecta un sistema ya registrado", %{path: path} do
      File.write!(path, Jason.encode!(%{"crm" => %{"dominio" => "crm.ventaenruta.com.mx"}}))

      assert MotorAlta.sistema_registrado?("crm", path)
      refute MotorAlta.sistema_registrado?("direem", path)

      assert {:error, mensaje} = MotorAlta.validar_nombre("crm", path)
      assert mensaje =~ "ya está registrado"
    end

    test "validar_nombre rechaza charset inválido antes de mirar el archivo", %{path: path} do
      assert {:error, mensaje} = MotorAlta.validar_nombre("CRM Malo!", path)
      assert mensaje =~ "no es un nombre válido"
    end
  end

  describe "generar_clave_base64/1" do
    test "genera algo distinto en cada llamada -- nunca se repite entre sistemas" do
      refute MotorAlta.generar_clave_base64() == MotorAlta.generar_clave_base64()
    end

    test "el tamaño pedido en bytes se refleja en un base64 más largo" do
      assert String.length(MotorAlta.generar_clave_base64(32)) < String.length(MotorAlta.generar_clave_base64(64))
    end
  end

  describe "manifiestos_k3s/2" do
    setup do
      {:ok, yaml: MotorAlta.manifiestos_k3s("direem", "ghcr.io/prettycore-13/metadata_stack:bc-abc-42")}
    end

    test "los 4 recursos usan el nombre derivado de <sistema>, nada hardcodeado", %{yaml: yaml} do
      assert yaml =~ "name: metadata-direem-env"
      assert yaml =~ "name: metadata-direem\n"
      assert yaml =~ "name: metadata-direem-ingress"
      assert yaml =~ "host: direem.ventaenruta.com.mx"
      assert yaml =~ ~s(DB_NAME_PSQL: "db_direem")
    end

    test "la imagen pasada se usa tal cual, nunca :latest por default", %{yaml: yaml} do
      assert yaml =~ "image: ghcr.io/prettycore-13/metadata_stack:bc-abc-42"
      refute yaml =~ ":latest"
    end

    test "las credenciales de DB vienen de aws-postgres-env, nunca copiadas al Secret nuevo", %{yaml: yaml} do
      assert yaml =~ "name: aws-postgres-env"
      refute yaml =~ "DB_PASSWORD_PSQL: \""
    end

    test "dos sistemas nunca comparten SECRET_KEY_BASE ni CLOAK_KEY" do
      yaml_a = MotorAlta.manifiestos_k3s("crm", "img:1")
      yaml_b = MotorAlta.manifiestos_k3s("crm", "img:1")

      [clave_a] = Regex.run(~r/SECRET_KEY_BASE: "([^"]+)"/, yaml_a, capture: :all_but_first)
      [clave_b] = Regex.run(~r/SECRET_KEY_BASE: "([^"]+)"/, yaml_b, capture: :all_but_first)

      refute clave_a == clave_b
    end
  end
end
