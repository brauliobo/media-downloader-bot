class Translator
  module Ollama

    API   = ENV['OLLAMA_HOST']
    MODEL = ENV['OLLAMA_MODEL']
    MARKER = '|||---SUBTITLEBLOCK---|||'

    def translate text, from:, to:
      to_iso   = to.to_s.downcase
      from_iso = from.to_s.downcase if from
      segments = text.is_a?(String) ? text.split(MARKER) : Array(text)

      translations = batch_translations(segments, from_iso: from_iso, to_iso: to_iso, to: to)
      # Fall back to one request per segment to keep the count and the order
      translations = segments.map { |segment| translate_alone(segment, to) } if translations.size != segments.size

      return translations.join(MARKER) if text.is_a?(String) && segments.size > 1
      return translations.first if text.is_a? String
      translations
    end

    private

    def batch_translations(segments, from_iso:, to_iso:, to:)
      content = chat(
        [
          { role: :system, content: system_prompt(to_iso, to) },
          { role: :user, content: { marker: MARKER, segments: segments, source_language_iso: from_iso, target_language_iso: to_iso }.to_json }
        ],
        format: 'json'
      )
      SymMash.new(JSON.parse(content)).translations
    rescue JSON::ParserError
      content.include?(MARKER) ? content.split(MARKER) : [content]
    end

    def translate_alone(segment, to)
      chat([
        { role: :system, content: "Translate the user's subtitle text into #{to}. Return ONLY the translated text with no extra words." },
        { role: :user, content: segment }
      ])
    end

    def chat(messages, **options)
      body = Utils::HTTP.post("#{API}/api/chat", { model: MODEL, temperature: 0, stream: false, messages: messages, **options }.to_json).body.to_s
      SymMash.new(JSON.parse(body)).dig(:message, :content).to_s.strip
    rescue JSON::ParserError
      body.to_s.strip
    end

    def system_prompt(to_iso, to)
      <<~PROMPT
        You are a professional translator specializing in documentary and TV series subtitles, specifically focusing on the series "The Curse of Oak Island". Your task is to translate the provided English text, block by block, into the TARGET LANGUAGE ISO: #{to_iso}.

        ABSOLUTE RULES:

        1.  TRANSLATE ONLY THE TEXT INTO the language identified by target_language_iso. The original text consists of multiple segments separated by the marker "#{MARKER}". Your response MUST contain EXACTLY the same number of segments, separated by the SAME marker "#{MARKER}". Do not add or remove markers. Translate the content of each segment individually. Do not include the original block number in your response.
        2.  CONTEXT AND CONTINUITY: This text is a subtitle. Segments that do not end with final punctuation (., !, ?) or a comma (,) likely continue into the next segment. Maintain the flow and meaning between these connected segments when translating. Preserve the original intent.
        3.  NUMBER OF SEGMENTS: Your final response MUST have the exact same number of segments (parts between "#{MARKER}") as the original input text. This is CRITICAL for subtitle reconstruction. Respond ONLY with the translated texts separated by the separator.
        4.  TRANSLATION OF LOCATIONS (Oak Island - ONLY IF target_language_iso == "pt"): For Brazilian Portuguese, translate the following place names: Money Pit -> Poço do Dinheiro, Smith's Cove -> Enseada Smith, Chappel Vault -> Cofre de Chappel, Garden Shaft -> Poço do Jardim, 90 Foot Stone -> Pedra dos 90 pés, Aladdin's Cave -> Caverna de Aladdin, Lot [Number] -> Lote [Número], starburst -> explosão estelar, starburst button -> botão explosão estelar, [number]th-century -> século [number], [number]th century -> século [number], [number]th centuries -> séculos [number], strap -> alça, western drumlin -> colina ocidental, eastern drumlin -> colina oriental, the swamp -> o pântano, Borehole [ID] -> Poço [ID], War Room -> sala de guerra, survey stakes -> estacas de pesquisa, feature -> estrutura, Eye of the Swamp -> Olho do Pântano, round feature -> estrutura circular, round foundation -> fundação circular, nail -> prego, Nolan's Cross -> Cruz de Nolan, token -> ficha, As a new day -> Enquanto um novo dia, Bead Site -> Área das Contas, South Cave -> Caverna Sul, Keyhole Chamber -> Câmara do Buraco de Fechadura, Keyhole Cave -> Caverna do Buraco de Fechadura, Triangle-shaped swamp -> Pântano em forma de triângulo, Blind Frog Ranch -> Fazenda Blind Frog, Skinwalker Ranch -> Rancho Skinwalker, Okay -> Ok. FOR OTHER LANGUAGES, use the most common translation in that language if applicable, or keep the original English names.
        5.  DO NOT TRANSLATE (General Rule): Keep "Oak Island" as "Oak Island". Keep proper names of people (Rick Lagina, Marty Lagina, etc.).
        6.  NATURALNESS: The translation must sound completely natural in the language identified by target_language_iso.
        7.  TONE AND STYLE: Maintain the informative and speculative tone of the original series.
        8.  REVIEW: Review to ensure accuracy, clarity, and consistency in the translation into #{to}.
        9.  RESPONSE FORMAT: Return a JSON object with a single key "translations" whose value is an array of strings. Each array entry must be EXACTLY the translation of the corresponding input segment, preserving order and count. Do not include any other keys or metadata.
        10. TRANSLATE FEET TO METERS: Example 1: 11 feet = 3.3 meters / Example 2: 179 feet = 54.5 meters. When the phrase "How deep are we?" appears, if the following text contains numbers, it refers to the excavation depth in feet, even if the word "feet" is omitted. You must identify these phrases and apply the feet-to-meters conversion in the translated subtitle. Example: - How deep are we? - We're at 78. (example translation: - How deep are we? - We are at 23,8 meters). Use a comma (,) as the decimal separator for meters in the output.
      PROMPT
    end
  end
end
