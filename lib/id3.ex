defmodule ID3 do
  import Bitwise

  def parse_tag(<<
      "ID3",
      major_version::integer,
      _revision::integer,
      _unsynchronized::size(1),
      extended_header::size(1),
      _experimental::size(1),
      _footer::size(1),
      0::size(4),
      tag_size_synchsafe::binary-size(4),
      rest::binary
  >>) do
    tag_size = decode_synchsafe_integer(tag_size_synchsafe)
    {major_version, extended_header, tag_size, rest}
    tag_size = decode_synchsafe_integer(tag_size_synchsafe)

    {rest, ext_header_size} =
      if extended_header == 1 do
        skip_extended_header(major_version, rest)
      else
        {rest, 0}
      end
    
    parse_frames(major_version, rest, tag_size - extended_header)
  end
  def parse_tag(_), do: %{}

  def parse_frames(major_version, data, tag_length_remaining, frames \\ [])
  def parse_frames(
      major_version,
      <<
        frame_id::binary-size(4),
        frame_size_maybe_synchsafe::binary-size(4),
        0::size(1),
        _tag_alter_preservation::size(1),
        _file_alter_preservation::size(1),
        _read_only::size(1),
        0::size(4),
        _grouping_identity::size(1),
        0::size(2),
        _compression::size(1),
        _encryption::size(1),
        _unsynchronized::size(1),
        _has_data_length_indicator::size(1),
		    _unused::size(1),
        rest::binary
      >>,
      tag_length_remaining,
      frames
  ) do
    frame_size =
      case major_version do
        4 ->
          decode_synchsafe_integer(frame_size_maybe_synchsafe)
        3 ->
          <<size::size(32)>> = frame_size_maybe_synchsafe
		      size
	    end

    total_frame_size = frame_size + 10
    next_tag_length_remaining = tag_length_remaining - total_frame_size

    result = decode_frame(frame_id, frame_size, rest)

    case result do
      {nil, rest, :halt} ->
        {Map.new(frames), rest}
  
      {nil, rest, :cont} ->
        parse_frames(major_version, rest, next_tag_length_remaining, frames)
  
      {new_frame, rest} ->
        parse_frames(major_version, rest, next_tag_length_remaining, [new_frame | frames])
    end
  end

  def parse_frames(_, data, tag_length_remaining, frames) when tag_length_remaining <= 0 do
    {Map.new(frames), data}
  end
  def parse_frames(_, data, _, frames) do
    {Map.new(frames), data}
  end

  def decode_synchsafe_integer(<<b>>) do
    b
  end
  
  def decode_synchsafe_integer(binary) do
    binary
    |> :binary.bin_to_list()
    |> Enum.reverse()
    |> Enum.with_index()
    |> Enum.reduce(0, fn {el, index}, acc ->
      acc ||| (el <<< (index * 7))
    end)
  end

  def convert_string(encoding, str) when encoding in [0, 3] do
    str
  end
  def convert_string(1, data) do
    {encoding, bom_length} = :unicode.bom_to_encoding(data)
    {_, string_data} = String.split_at(data, bom_length)
    :unicode.characters_to_binary(string_data, encoding)
  end
  def convert_string(2, data) do
    :unicode.characters_to_binary(data, {:utf16, :big})
  end

  def decode_string(encoding, max_byte_size, data) when encoding in [1, 2] do
    {str_data, rest} = get_double_null_terminated(data, max_byte_size)
    {convert_string(encoding, str_data), byte_size(str_data) + 2, rest}
  end

  def decode_string(encoding, max_byte_size, data) when encoding in [0, 3] do
    case :binary.split(data, <<0>>) do
      [str, rest] when byte_size(str) + 1 <= max_byte_size ->
      {str, byte_size(str) + 1, rest}
  
    _ ->
      {str, rest} = :erlang.split_binary(data, max_byte_size)
      {str, max_byte_size, rest}
    end
  end

  def get_double_null_terminated(data, max_byte_size, acc \\ [])

  def get_double_null_terminated(rest, 0, acc) do
    {acc |> Enum.reverse() |> :binary.list_to_bin(), rest}
  end

  def get_double_null_terminated(<<0, 0, rest::binary>>, _, acc) do
    {acc |> Enum.reverse() |> :binary.list_to_bin(), rest}
  end

  def get_double_null_terminated(<<a::size(8), b::size(8), rest::binary>>, max_byte_size, acc) do
    next_max_byte_size = max_byte_size - 2
    get_double_null_terminated(rest, next_max_byte_size, [b, a | acc])
  end

  def decode_frame("TXXX", frame_size, <<text_encoding::size(8), rest::binary>>) do
    {description, desc_size, rest} = decode_string(text_encoding, frame_size - 1, rest)
    {value, _, rest} = decode_string(text_encoding, frame_size - 1 - desc_size, rest)
    {{"TXXX", {description, value}}, rest}
  end
  def decode_frame("COMM", frame_size, <<text_encoding::size(8), language::binary-size(3), rest::binary>>) do
    {short_desc, desc_size, rest} = decode_string(text_encoding, frame_size - 4, rest)
    {value, _, rest} = decode_string(text_encoding, frame_size - 4 - desc_size, rest)
    {{"COMM", {language, short_desc, value}}, rest}
  end
  def decode_frame("APIC", frame_size, <<text_encoding::size(8), rest::binary>>) do
    {mime_type, mime_len, rest} = decode_string(0, frame_size - 1, rest)
  
    <<picture_type::size(8), rest::binary>> = rest
  
    {description, desc_len, rest} = decode_string(text_encoding, frame_size - 1 - mime_len - 1, rest)
  
    image_data_size = frame_size - 1 - mime_len - 1 - desc_len
    {image_data, rest} = :erlang.split_binary(rest, image_data_size)
  
    {{"APIC", {mime_type, picture_type, description, image_data}}, rest}
  end
  def decode_frame(id, frame_size, rest) do
    cond do
      Regex.match?(~r/^T[0-9A-Z]+$/, id) ->
      decode_text_frame(id, frame_size, rest)
  
      id in @declared_frame_ids ->
        <<_frame_data::binary-size(frame_size), rest::binary>> = rest
        {nil, rest, :cont}
  
      true ->
        {nil, rest, :halt}
    end
  end

  def decode_text_frame(id, frame_size, <<text_encoding::size(8), rest::binary>>) do
    {strs, rest} = decode_string_sequence(text_encoding, frame_size - 1, rest)
    {{id, strs}, rest}
  end
  
  def decode_string_sequence(encoding, max_byte_size, data, acc \\ [])
  
  def decode_string_sequence(_, max_byte_size, data, acc) when max_byte_size <= 0 do
    {Enum.reverse(acc), data}
  end
  
  def decode_string_sequence(encoding, max_byte_size, data, acc) do
    {str, str_size, rest} = decode_string(encoding, max_byte_size, data)
    decode_string_sequence(encoding, max_byte_size - str_size, rest, [str | acc])
  end

  def skip_extended_header(3, <<
	  ext_header_size::size(32),
	  _flags::size(16),
	  _padding_size::size(32),
	  rest::binary
  >>) do
    remaining_ext_header_size = ext_header_size - 6
    <<_::binary-size(remaining_ext_header_size), rest::binary>> = rest
    {rest, ext_header_size}
  end

  def skip_extended_header(4, <<
	  ext_header_size_synchsafe::size(32),
	  1::size(8),
	  _flags::size(8),
	  rest::binary
  >>) do
    ext_header_size = decode_synchsafe_integer(ext_header_size_synchsafe)
    remaining_ext_header_size = ext_header_size - 6
    <<_::binary-size(remaining_ext_header_size), rest::binary>> = rest
    {rest, ext_header_size}
  end
end