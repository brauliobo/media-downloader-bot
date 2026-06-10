require 'timeout'
require 'iso-639'
require_relative '../utils/sh'
require_relative '../utils/safety'

class Ocr
  module Tesseract

    DEFAULT_LANG = 'eng'.freeze

    def self.transcribe image_path, opts: nil, **_kwargs
      lang_code = opts&.dig(:lang) || opts&.dig('lang') || DEFAULT_LANG
      lang = map_to_tesseract_lang(lang_code)
      cmd = "tesseract #{Sh.escape(image_path)} stdout -l #{Sh.escape(lang)}"
      stdout, stderr, status = Sh.run(cmd)
      raise "Tesseract failed: #{stderr}" if !status.success? and stderr.present?
      text = stdout.strip
      SymMash.new(content: { text: text })
    end

    def self.map_to_tesseract_lang code
      return DEFAULT_LANG unless code.to_s.match?(/\A[a-z]{2,3}\z/i)
      return Utils::Safety.tesseract_lang(code, fallback: DEFAULT_LANG) if code.to_s.length == 3

      entry = ISO_639.find_by_code(code.to_s)
      entry&.alpha3_bibliographic || entry&.alpha3 || DEFAULT_LANG
    end

  end
end
