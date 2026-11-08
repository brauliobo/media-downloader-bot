require 'iso-639'

module Language
  # "pt-BR", "por" and "Portuguese" all say "pt".
  module Code
    # Written without spaces between words.
    SPACELESS = %w[zh ja th lo km my].freeze

    def self.normalize(lang)
      return if lang.nil?

      raw  = lang.to_s.strip.downcase
      base = raw.split(/[-_]/, 2).first
      entry = ISO_639.find_by_code(raw) || ISO_639.find_by_code(base) || ISO_639.find_by_english_name(raw.capitalize)
      entry&.alpha2
    end

    def self.spaceless?(lang) = SPACELESS.include?(normalize(lang))
  end
end
