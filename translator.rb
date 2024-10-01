class Translator

  NLLB_API = ENV['NLLB_API']

  ISO_TO_NLLB = SymMash.new(
    'af' => 'afr_Latn', # Afrikaans
    'ar' => 'arb_Arab', # Arabic (Alternative scripts: acm_Arab, acq_Arab, aeb_Arab, ajp_Arab, apc_Arab, ars_Arab, ary_Arab, arz_Arab)
    'az' => 'azj_Latn', # Azerbaijani (Alternative script: azb_Arab)
    'ba' => 'bak_Cyrl', # Bashkir
    'be' => 'bel_Cyrl', # Belarusian
    'bg' => 'bul_Cyrl', # Bulgarian
    'bn' => 'ben_Beng', # Bengali
    'bs' => 'bos_Latn', # Bosnian
    'ca' => 'cat_Latn', # Catalan
    'cs' => 'ces_Latn', # Czech
    'cy' => 'cym_Latn', # Welsh
    'da' => 'dan_Latn', # Danish
    'de' => 'deu_Latn', # German
    'el' => 'ell_Grek', # Greek
    'en' => 'eng_Latn', # English
    'es' => 'spa_Latn', # Spanish
    'et' => 'est_Latn', # Estonian
    'eu' => 'eus_Latn', # Basque
    'fa' => 'pes_Arab', # Persian (Alternative scripts: prs_Arab, pbt_Arab)
    'fi' => 'fin_Latn', # Finnish
    'fr' => 'fra_Latn', # French
    'ga' => 'gle_Latn', # Irish
    'gl' => 'glg_Latn', # Galician
    'gu' => 'guj_Gujr', # Gujarati
    'ha' => 'hau_Latn', # Hausa
    'he' => 'heb_Hebr', # Hebrew
    'hi' => 'hin_Deva', # Hindi
    'hr' => 'hrv_Latn', # Croatian
    'hu' => 'hun_Latn', # Hungarian
    'hy' => 'hye_Armn', # Armenian
    'id' => 'ind_Latn', # Indonesian
    'is' => 'isl_Latn', # Icelandic
    'it' => 'ita_Latn', # Italian
    'ja' => 'jpn_Jpan', # Japanese
    'ka' => 'kat_Geor', # Georgian
    'kk' => 'kaz_Cyrl', # Kazakh
    'km' => 'khm_Khmr', # Khmer
    'kn' => 'kan_Knda', # Kannada
    'ko' => 'kor_Hang', # Korean
    'ku' => 'ckb_Arab', # Kurdish (Alternative scripts: crh_Latn, knc_Arab, knc_Latn, kmr_Latn)
    'ky' => 'kir_Cyrl', # Kyrgyz
    'lb' => 'ltz_Latn', # Luxembourgish
    'lo' => 'lao_Laoo', # Lao
    'lt' => 'lit_Latn', # Lithuanian
    'lv' => 'lvs_Latn', # Latvian
    'mg' => 'mag_Deva', # Magahi
    'mi' => 'mri_Latn', # Māori
    'mk' => 'mkd_Cyrl', # Macedonian
    'ml' => 'mal_Mlym', # Malayalam
    'mn' => 'mya_Mymr', # Mongolian (Alternative scripts: khk_Cyrl)
    'mr' => 'mar_Deva', # Marathi
    'ms' => 'zsm_Latn', # Malay
    'mt' => 'mlt_Latn', # Maltese
    'my' => 'mya_Mymr', # Burmese
    'nl' => 'nld_Latn', # Dutch
    'no' => 'nob_Latn', # Norwegian Bokmål (Alternative: nno_Latn for Norwegian Nynorsk)
    'pa' => 'pan_Guru', # Punjabi
    'pl' => 'pol_Latn', # Polish
    'pt' => 'por_Latn', # Portuguese
    'ro' => 'ron_Latn', # Romanian
    'ru' => 'rus_Cyrl', # Russian
    'sa' => 'san_Deva', # Sanskrit
    'sd' => 'snd_Arab', # Sindhi (Alternative script: snd_Deva)
    'si' => 'sin_Sinh', # Sinhala
    'sk' => 'slk_Latn', # Slovak
    'sl' => 'slv_Latn', # Slovenian
    'sm' => 'smo_Latn', # Samoan
    'sn' => 'sna_Latn', # Shona
    'so' => 'som_Latn', # Somali
    'sq' => 'sqi_Latn', # Albanian (Missing in previous list but included here)
    'sr' => 'srp_Cyrl', # Serbian
    'sv' => 'swe_Latn', # Swedish
    'sw' => 'swh_Latn', # Swahili
    'ta' => 'tam_Taml', # Tamil (Alternative scripts: taq_Latn, taq_Tfng)
    'te' => 'tel_Telu', # Telugu
    'th' => 'tha_Thai', # Thai
    'tk' => 'tuk_Latn', # Turkmen
    'tr' => 'tur_Latn', # Turkish
    'uk' => 'ukr_Cyrl', # Ukrainian
    'ur' => 'urd_Arab', # Urdu
    'uz' => 'uzn_Latn', # Uzbek
    'vi' => 'vie_Latn', # Vietnamese
    'yi' => 'ydd_Hebr', # Yiddish
    'yo' => 'yor_Latn', # Yoruba
    'zh' => 'zho_Hans', # Chinese (Simplified) (Alternative scripts: zho_Hant, yue_Hant)
    'zu' => 'zul_Latn'  # Zulu
  )

  class_attribute :http
  self.http = Mechanize.new

  def self.translate text, from:, to:
    from,to = ISO_TO_NLLB.values_at from, to
    res = http.post "#{NLLB_API}/translate", source: text, src_lang: from, tgt_lang: to
    res = SymMash.new JSON.parse res.body
    tr  = res.translation
    return tr.first if text.is_a? String
    tr
  end

  def self.translate_srt srt, from:, to:
    srt    = SRT::File.parse_string srt
    lines  = srt.lines.flat_map{ |line| line.text }
    tlines = translate lines, from: from, to: to

    i = 0
    srt.lines.each do |line|
      line.text = line.text.map{ |segment| tlines[i].tap{ i+= 1 } }
    end

    srt.to_s
  end

end

