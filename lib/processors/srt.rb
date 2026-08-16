require_relative 'file'
require_relative '../translator'

module Processors
  class Srt < File
    self.attr = :document

    def self.srt_file?(doc_or_msg)
      doc = doc_or_msg.respond_to?(:document) ? doc_or_msg.document : doc_or_msg
      doc&.file_name.to_s.downcase.end_with?('.srt')
    end

    def self.can_handle?(ctx)
      return false unless srt_file?(ctx.msg)
      line = Utils::InputParser.input_text(ctx)
      line.to_s.match?(/\blang=\w+/)
    end

    def handle_input(i, **_kwargs)
      raise 'no input provided' unless i
      @stl&.update 'translating'

      to_lang = Subtitler.normalize_lang(i.opts.slang)
      raise "unsupported target language: #{i.opts.slang}" unless to_lang

      srt_content = ::File.read(i.fn_in)
      subtitle = Subtitler::Subtitle.from_srt(srt_content)
      subtitle.translate_srt!(to: to_lang, translator: Translator)

      out_path = i.fn_in.sub(/\.srt\z/i, ".#{to_lang}.srt")
      ::File.binwrite(out_path, "\uFEFF" + subtitle.to_srt.encode('UTF-8'))

      i.fn_out = out_path
      i.type = SymMash.new(name: :document)
      i.mime = 'application/x-subrip'
      i
    end
  end
end
