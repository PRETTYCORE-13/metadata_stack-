defmodule MetadataApp.Autenticacion.ImagenLogo do
  @moduledoc """
  Valida el binario de un logo de empresa y lee sus dimensiones, sin
  dependencias ni acceso a la base (SPEC-SYS-3009202601 D4).

  El formato se reconoce por los bytes mágicos del contenido, nunca por la
  extensión del archivo: un SVG (que puede llevar script) renombrado a
  `.png` se rechaza igual que cualquier otro formato no permitido.
  """

  @max_bytes 200_000

  # Fuera de este rango (ancho / alto) el logo cabe en la caja de la top
  # bar (32 × 160 px), pero se ve más chico de lo ideal. Es solo un aviso.
  @proporcion_min 2
  @proporcion_max 6

  @type resultado :: %{
          content_type: String.t(),
          ancho: pos_integer(),
          alto: pos_integer(),
          tamano_bytes: non_neg_integer(),
          aviso_proporcion: boolean()
        }

  @doc "Tamaño máximo aceptado, en bytes."
  def max_bytes, do: @max_bytes

  @doc """
  Devuelve `{:ok, resultado}` o `{:error, mensaje}` con un mensaje en
  español listo para mostrar.
  """
  @spec inspeccionar(binary()) :: {:ok, resultado()} | {:error, String.t()}
  def inspeccionar(binario) when is_binary(binario) do
    tamano = byte_size(binario)

    cond do
      tamano > @max_bytes ->
        {:error, "El logo no puede pasar de 200 KB."}

      true ->
        with {:ok, content_type} <- formato(binario),
             {:ok, {ancho, alto}} <- dimensiones(content_type, binario) do
          {:ok,
           %{
             content_type: content_type,
             ancho: ancho,
             alto: alto,
             tamano_bytes: tamano,
             aviso_proporcion: ancho < alto * @proporcion_min or ancho > alto * @proporcion_max
           }}
        end
    end
  end

  defp formato(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _::binary>>), do: {:ok, "image/png"}
  defp formato(<<"GIF87a", _::binary>>), do: {:ok, "image/gif"}
  defp formato(<<"GIF89a", _::binary>>), do: {:ok, "image/gif"}
  defp formato(<<0xFF, 0xD8, 0xFF, _::binary>>), do: {:ok, "image/jpeg"}
  defp formato(<<"RIFF", _::binary-4, "WEBP", _::binary>>), do: {:ok, "image/webp"}
  defp formato(_), do: {:error, "Formato no permitido: usa PNG, JPG, WebP o GIF."}

  defp dimensiones(content_type, binario) do
    case leer_dimensiones(content_type, binario) do
      {ancho, alto} when is_integer(ancho) and is_integer(alto) and ancho > 0 and alto > 0 ->
        {:ok, {ancho, alto}}

      _ ->
        {:error, "La imagen está dañada o incompleta."}
    end
  end

  # PNG: el primer chunk siempre es IHDR (ancho, alto en big-endian).
  defp leer_dimensiones(
         "image/png",
         <<_firma::binary-8, _len::32, "IHDR", ancho::32, alto::32, _::binary>>
       ),
       do: {ancho, alto}

  # GIF: "Logical Screen Descriptor" justo después de la firma.
  defp leer_dimensiones(
         "image/gif",
         <<_firma::binary-6, ancho::little-16, alto::little-16, _::binary>>
       ),
       do: {ancho, alto}

  defp leer_dimensiones("image/jpeg", <<0xFF, 0xD8, resto::binary>>), do: jpeg_segmentos(resto)

  defp leer_dimensiones("image/webp", <<"RIFF", _::binary-4, "WEBP", resto::binary>>),
    do: webp(resto)

  defp leer_dimensiones(_, _), do: nil

  # JPEG: se recorren los segmentos hasta el primer SOFn, que trae alto y
  # ancho. C4 (DHT), C8 (JPG) y CC (DAC) comparten rango pero no son SOF.
  defp jpeg_segmentos(<<0xFF, 0xFF, resto::binary>>), do: jpeg_segmentos(<<0xFF, resto::binary>>)

  defp jpeg_segmentos(<<0xFF, marcador, _len::16, _precision, alto::16, ancho::16, _::binary>>)
       when marcador in 0xC0..0xCF and marcador not in [0xC4, 0xC8, 0xCC],
       do: {ancho, alto}

  # Marcadores sin longitud (RSTn, TEM).
  defp jpeg_segmentos(<<0xFF, marcador, resto::binary>>)
       when marcador in 0xD0..0xD7 or marcador == 0x01,
       do: jpeg_segmentos(resto)

  # EOI o SOS antes de cualquier SOF: no hay dimensiones.
  defp jpeg_segmentos(<<0xFF, marcador, _::binary>>) when marcador in [0xD9, 0xDA], do: nil

  defp jpeg_segmentos(<<0xFF, _marcador, len::16, resto::binary>>) when len >= 2 do
    salto = len - 2

    case resto do
      <<_::binary-size(^salto), siguiente::binary>> -> jpeg_segmentos(siguiente)
      _ -> nil
    end
  end

  defp jpeg_segmentos(_), do: nil

  # WebP con pérdida: frame tag (3 bytes) + código de inicio 9D 01 2A; las
  # dimensiones ocupan 14 bits de cada campo de 16 (los 2 altos son escala).
  defp webp(
         <<"VP8 ", _::binary-4, _tag::binary-3, 0x9D, 0x01, 0x2A, ancho::little-16,
           alto::little-16, _::binary>>
       ),
       do: {Bitwise.band(ancho, 0x3FFF), Bitwise.band(alto, 0x3FFF)}

  # WebP sin pérdida: firma 0x2F + 28 bits little-endian (ancho-1, alto-1).
  defp webp(<<"VP8L", _::binary-4, 0x2F, bits::little-32, _::binary>>),
    do: {Bitwise.band(bits, 0x3FFF) + 1, Bitwise.band(Bitwise.bsr(bits, 14), 0x3FFF) + 1}

  # WebP extendido (transparencia/animación): lienzo en 24 bits (ancho-1, alto-1).
  defp webp(
         <<"VP8X", _::binary-4, _flags::binary-4, ancho::little-24, alto::little-24, _::binary>>
       ),
       do: {ancho + 1, alto + 1}

  defp webp(_), do: nil
end
