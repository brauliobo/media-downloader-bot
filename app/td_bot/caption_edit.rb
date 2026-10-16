module TDBot
  # Swaps a text for another one in a TDLib formatted text: the entities left of it stay, those inside it go and those after
  # it move by the change in length. TDLib offsets and lengths count UTF-16 code units. A blank `from` appends `to`.
  module CaptionEdit
    module_function

    def replace(caption, from, to)
      text  = caption.text
      index = from.blank? ? text.size : (text.index(from) or raise ArgumentError, "#{from.inspect} is not in the caption")
      { '@type' => 'formattedText', 'text' => from.blank? ? "#{text}\n\n#{to}" : text.sub(from) { to },
        'entities' => shifted(caption.entities, utf16(text[0, index]), utf16(from), utf16(to)) }
    end

    def shifted(entities, start, from_length, to_length)
      stop = start + from_length
      entities.reject { |entity| entity.offset < stop && entity.offset + entity.length > start }
              .map { |entity| entity.to_h.merge(offset: entity.offset >= stop ? entity.offset + to_length - from_length : entity.offset) }
    end

    def utf16(text) = text.encode('UTF-16LE').bytesize / 2
  end
end
