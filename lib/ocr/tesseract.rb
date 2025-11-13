require 'timeout'
require 'iso-639'
require_relative '../utils/sh'

class Ocr
  module Tesseract

    DEFAULT_LANG = 'eng'.freeze

    def self.transcribe image_path, opts: nil, **_kwargs
      lang_code = opts&.dig(:lang) || opts&.dig('lang') || DEFAULT_LANG
      lang = map_to_tesseract_lang(lang_code)
      cmd = "tesseract #{Sh.escape(image_path)} stdout -l #{lang}"
      stdout, stderr, status = Sh.run(cmd)
      raise "Tesseract failed: #{stderr}" if !status.success? and stderr.present?
      text = stdout.strip
      SymMash.new(content: { text: text })
    end

    def self.map_to_tesseract_lang code
      return code if code.to_s.length == 3
      entry = ISO_639.find_by_code(code.to_s)
      entry&.alpha3_bibliographic || entry&.alpha3 || DEFAULT_LANG
    end

  end
end
