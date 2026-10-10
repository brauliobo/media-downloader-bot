module Ewprs
  class TranslationValidator
    # What the validator knows about words: the common words of a source language, the prose that may stay
    # untranslated in a target, and the phrases that give away a translation left half in English.
    module Lexicon
      SOURCE_WORDS = {
        'en' => %w[
          a about above after again all also although an and another any are as at be because been before being
          below between body both but by call called came can could cosmic did do does down during each english entity even
          every few first for force fountain from further get go got had has have he her here him his how human i if in into
          is it its just know last life like made make many may me mean means might mind more most much must my new no nor
          not now of off old on once one only or other our out over own people power same said say second see she
          sentence should so society some soul source spiritual spraying still such supreme take than that the their them then there these title
          they thing this those though three through time to too two under up us very was way we well were what when
          water where which while who whom why will with world would you your
        ].to_h { |word| [word, true] }.freeze
      }.freeze
      SOURCE_SUFFIXES = {
        'en' => /(?:able|hood|ible|ise|ised|ises|ising|ity|ive|less|ly|ment|ness|ous|ship|sion|tion|ward|wise|ize|ized|izes|izing)\z/
      }.freeze
      RETAINED_SOURCE_WORDS = {
        'de' => %w[
          although because called can cases chapter conceived could each edition further however
          descended encourage example examples feeder hence illiterate informing linseed means originally otherwise publication
          published second secondly section should similarly so-called states therefore these those
          throughout translation respectively used whereas which within without would
        ].to_h { |word| [word, true] }.freeze,
        'fr' => %w[further nucleus salvation stamina].to_h { |word| [word, true] }.freeze
      }.freeze
      RETAINED_HYPHEN_COMPONENTS = {
        'de' => %w[descended those].to_h { |word| [word, true] }.freeze
      }.freeze
      RETAINED_ATTACHED_COMPONENTS = {
        'de' => %w[respectively].to_h { |word| [word, true] }.freeze
      }.freeze
      SOURCE_PROSE_ANCHORS = {
        'en' => %w[
          absolute accepted acoustic afraid affectionate anahata anus attributive attains
          attained author becomes became beatitude bengalee behind bliss body boy cannot
          categories characteristics come controls cord dance declare definition derived
          directly divided divine evening example examples experience expression external
          four flare genitary grow hand hence high here hindi human ideation include
          includes included instance kinds language languages later leg literature little
          machine meaning means meditation millet moved name next organ organs organization
          east eastern offering overjoyed path peace pahari peanut philosophy prefix
          previous chapter beginning similarly therefore likewise however according
          moreover furthermore nevertheless nonetheless consequently
          propensities published recognizes religion remain remains remembering school science
          secondly seed self-knowledge says shyness sorghum spelled starts stick supreme
          ten these triple varieties using vaishnavite vocal war western wife within would
          yielding
          knowable knows soybean
        ].to_h { |word| [word, true] }.freeze,
        'de' => %w[definition].to_h { |word| [word, true] }.freeze
      }.freeze
      SOURCE_PROSE_CONNECTORS = {
        'en' => %w[
          after although among another because before between called comes first from has have
          however if in include includes included is language languages means now of originally
          published remains so than that the these this those through translated used using when
          where which while with word words are
        ].to_h { |word| [word, true] }.freeze
      }.freeze
      PROTECTED_CONNECTORS = {
        'de' => %w[and are is or].to_h { |word| [word, true] }.freeze
      }.freeze
      TARGET_SHARED_WORDS = {
        'es' => %w[no oh].to_h { |word| [word, true] }.freeze
      }.freeze
      TARGET_SHARED_PHRASES = {
        'de' => [%w[negative evolution].freeze].freeze
      }.freeze
      CJK_TARGET = %w[ja zh].to_h { |language| [language, true] }.freeze
      OMITTABLE_ARTICLES = %w[a an the].to_h { |word| [word, true] }.freeze
      OMITTABLE_SOURCE_WORDS = {
        'ar' => OMITTABLE_ARTICLES,
        'ja' => OMITTABLE_ARTICLES,
        'zh' => OMITTABLE_ARTICLES
      }.freeze
      def self.retained_english_span(phrase)
        /(?<![A-Za-z])#{Regexp.escape(phrase)}(?![A-Za-z])/i
      end
      def self.retained_english_phrases(*phrases)
        phrases.to_h { |phrase| [retained_english_span(phrase), 'retained English phrase'] }
      end
      RETAINED_ENGLISH_IDIOMS = retained_english_phrases(
        'in the same way', 'in the literal sense', 'in the same order',
        'from the external toward', 'statement of meaning', 'unable to read or write',
        'serving as examples', 'flax seed', 'throughout Southeast Asia',
        'introduce or instill', 'such efforts', 'all rights reserved',
        'online additional information', 'next chapter', 'previous chapter', 'beginning of book'
      ).freeze
      ENGLISH_DISCOURSE_OPENERS = retained_english_phrases(
        'according to', 'in addition', 'for example', 'for instance',
        'similarly', 'therefore', 'likewise', 'however', 'moreover',
        'furthermore', 'nevertheless', 'nonetheless', 'consequently'
      ).freeze
      ALLOWED_ENGLISH_HYPHENS = %w[extro-internal intro-external].to_h { |word| [word, true] }.freeze
      ENGLISH_HYPHEN_HEADS = %w[
        all self well so non over under out up down mid cross half full ever never
      ].to_h { |word| [word, true] }.freeze
      ENGLISH_HYPHEN_TAIL = /(?:ing|ed|er|est|ive|ous|al|ly|ness|ment|tion|sion|able|ible|ful|less|ward|wise|ized|izing)\z/
      ENGLISH_HYPHENATED_COMPOUND = /(?<![A-Za-z])[A-Za-z]{2,}(?:-[A-Za-z]{2,})+(?![A-Za-z])/
      TARGET_INVALID_PHRASES = {
        'de' => {
          /\bdefinition of\b/i => 'retained English definition prose',
          /\bin English in the\b/i => 'retained English publication prose',
          /\bof the cosmic mind\b/i => 'retained English phrase',
          /\bsome examples are\b/i => 'retained English example prose',
        }.freeze,
        'fr' => {
          /\blorsque (?:un|une)\b/i => 'invalid French elision',
          /\bce univers\b/i          => 'invalid French demonstrative',
        }.freeze
      }.freeze
    end
  end
end
