defmodule MetadataApp.Autenticacion.ImagenLogoTest do
  use ExUnit.Case, async: true

  alias MetadataApp.Autenticacion.ImagenLogo

  # WebP reales de 1×1 producidos por libwebp (los mismos que usa la
  # detección de soporte WebP de Modernizr), uno por variante de encabezado.
  @webp_vp8 Base.decode64!("UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEADsD+JaQAA3AAAAAA")
  @webp_vp8l Base.decode64!("UklGRhoAAABXRUJQVlA4TA0AAAAvAAAAEAcQERGIiP4HAA==")
  @webp_vp8x Base.decode64!(
               "UklGRjoAAABXRUJQVlA4WAoAAAAQAAAAAAAAAAAAQUxQSAwAAAARBxAR/Q9ERP8DAABWUDggGAAAABQBAJ0BKgEAAQAAAP4AAA3AAP7mtQAAAA=="
             )

  defp png(ancho, alto) do
    <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 13::32, "IHDR", ancho::32, alto::32, 8, 6, 0, 0, 0,
      0::32>>
  end

  defp gif(ancho, alto), do: <<"GIF89a", ancho::little-16, alto::little-16, 0, 0, 0, 0x3B>>

  # SOI + APP0 (JFIF) + DHT (C4, no es SOF) + SOF2 (progresivo).
  defp jpeg(ancho, alto) do
    app0 = <<0xFF, 0xE0, 16::16, "JFIF", 0, 1, 1, 0, 0, 1, 0, 1, 0, 0>>
    dht = <<0xFF, 0xC4, 5::16, 0, 0, 0>>
    sof = <<0xFF, 0xC2, 11::16, 8, alto::16, ancho::16, 1, 1, 0x11, 0>>
    <<0xFF, 0xD8>> <> app0 <> dht <> sof <> <<0xFF, 0xD9>>
  end

  describe "formatos aceptados y dimensiones" do
    test "PNG" do
      assert {:ok, %{content_type: "image/png", ancho: 320, alto: 64, aviso_proporcion: false}} =
               ImagenLogo.inspeccionar(png(320, 64))
    end

    test "GIF" do
      assert {:ok, %{content_type: "image/gif", ancho: 300, alto: 100}} =
               ImagenLogo.inspeccionar(gif(300, 100))
    end

    test "JPEG salta segmentos que no son SOF (APP0, DHT) hasta encontrar el SOF" do
      assert {:ok, %{content_type: "image/jpeg", ancho: 640, alto: 128}} =
               ImagenLogo.inspeccionar(jpeg(640, 128))
    end

    test "WebP con pérdida (VP8), sin pérdida (VP8L) y extendido (VP8X)" do
      for webp <- [@webp_vp8, @webp_vp8l, @webp_vp8x] do
        assert {:ok, %{content_type: "image/webp", ancho: 1, alto: 1}} =
                 ImagenLogo.inspeccionar(webp)
      end
    end

    test "WebP VP8X lee el lienzo de 24 bits" do
      <<inicio::binary-24, _::binary-6, resto::binary>> = @webp_vp8x
      webp = inicio <> <<319::little-24, 63::little-24>> <> resto
      assert {:ok, %{ancho: 320, alto: 64}} = ImagenLogo.inspeccionar(webp)
    end

    test "tamano_bytes es el tamaño real del binario" do
      binario = png(320, 64)
      assert {:ok, %{tamano_bytes: tamano}} = ImagenLogo.inspeccionar(binario)
      assert tamano == byte_size(binario)
    end
  end

  describe "rechazos" do
    test "SVG, aunque venga como si fuera PNG" do
      svg = ~s|<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>|
      assert {:error, "Formato no permitido" <> _} = ImagenLogo.inspeccionar(svg)
    end

    test "texto plano y binario vacío" do
      assert {:error, "Formato no permitido" <> _} = ImagenLogo.inspeccionar("hola")
      assert {:error, "Formato no permitido" <> _} = ImagenLogo.inspeccionar("")
    end

    test "más de 200 KB" do
      grande = png(320, 64) <> :binary.copy(<<0>>, ImagenLogo.max_bytes())
      assert {:error, "El logo no puede pasar de 200 KB."} = ImagenLogo.inspeccionar(grande)
    end

    test "exactamente 200 KB se acepta" do
      base = png(320, 64)
      exacto = base <> :binary.copy(<<0>>, ImagenLogo.max_bytes() - byte_size(base))
      assert {:ok, _} = ImagenLogo.inspeccionar(exacto)
    end

    test "archivos truncados o con dimensiones en cero" do
      assert {:error, "La imagen está dañada" <> _} =
               ImagenLogo.inspeccionar(binary_part(png(320, 64), 0, 12))

      assert {:error, "La imagen está dañada" <> _} = ImagenLogo.inspeccionar(png(0, 64))

      assert {:error, "La imagen está dañada" <> _} =
               ImagenLogo.inspeccionar(<<0xFF, 0xD8, 0xFF, 0xD9>>)

      assert {:error, "La imagen está dañada" <> _} =
               ImagenLogo.inspeccionar(binary_part(@webp_vp8, 0, 20))
    end
  end

  describe "aviso de proporción" do
    test "cuadrada (1:1) y muy alargada (8:1) avisan; 2:1 y 6:1 no" do
      assert {:ok, %{aviso_proporcion: true}} = ImagenLogo.inspeccionar(png(64, 64))
      assert {:ok, %{aviso_proporcion: true}} = ImagenLogo.inspeccionar(png(512, 64))
      assert {:ok, %{aviso_proporcion: false}} = ImagenLogo.inspeccionar(png(128, 64))
      assert {:ok, %{aviso_proporcion: false}} = ImagenLogo.inspeccionar(png(384, 64))
    end

    test "vertical avisa" do
      assert {:ok, %{aviso_proporcion: true}} = ImagenLogo.inspeccionar(png(64, 320))
    end
  end
end
