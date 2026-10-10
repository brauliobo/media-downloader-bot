module Language
  # Models are told "translate into Japanese", not "into ja".
  module Name
    TARGET_VARIANTS = { 'pt' => 'Brazilian Portuguese', 'zh' => 'Simplified Chinese' }.freeze

    def self.english(lang)
      code = Code.normalize(lang)
      (code && ISO_639.find_by_code(code).english_name.split(';').first) || lang.to_s.downcase
    end

    # What a translation is written in, which for some languages is a variant of the language.
    def self.target(lang) = TARGET_VARIANTS.fetch(Code.normalize(lang)) { english(lang) }
  end
end
