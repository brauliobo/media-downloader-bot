require 'fileutils'
require 'time'

require_relative '../jsonl_store'
require_relative 'sentence_splitter'
require_relative 'sanskrit_lexicon'
require_relative 'translator'
require_relative 'translation_markup'
require_relative 'translation_validator'
require_relative 'translation_batch/cache_management'
require_relative 'translation_batch/document_renderer'
require_relative 'translation_batch/document_unitizer'
require_relative 'translation_batch/source_management'
require_relative 'translation_batch/translation_restoration'
require_relative 'translation_batch/unit_preparation'

module Ewprs
  class TranslationBatch
    include TranslationMarkup
    include CacheManagement
    include DocumentRenderer
    include DocumentUnitizer
    include SourceManagement
    include TranslationRestoration
    include UnitPreparation

    PROMPT_VERSION = 10
    BATCH_SIZE     = 50
    MAX_UNIT_CHARS = 800
    MAX_INLINE_EDITORIAL_CHARS = 80
    TOKEN_RETRIES  = 2

    class ProtectedTokenError < StandardError; end

    Entry = Struct.new(:kind, :path, keyword_init: true) do
      def slug = File.basename(path, File.extname(path))
    end

    Document = Struct.new(:entry, :template, :encoding, :mode, :raw, keyword_init: true)
    Unit     = Struct.new(:key, :source, :prepared, :tokens, :leading, :trailing, keyword_init: true)

    attr_reader :root, :source_language, :target, :source_ref, :branch, :cache_path, :translator, :stdout,
                :validator

    def initialize(root:, source_language: 'en', target: 'pt', source_ref: '7.5', branch: '7.5-pt', cache: nil,
                   translator: Translator.new, stdout: $stdout)
      @root            = File.expand_path(root)
      @source_language = source_language
      @target          = target
      @source_ref      = source_ref
      @branch          = branch
      @cache_path      = File.expand_path(cache || "tmp/ewprs_translations/#{branch}.jsonl", Dir.pwd)
      @translator      = translator
      @stdout          = stdout
      @lexicon         = SanskritLexicon.new(@root)
      @validator       = TranslationValidator.new(source_language: source_language, target_language: target)
      @units           = {}
      @protected       = 0
    end

    def plan(only: nil)
      documents = prepare_documents(entries(only: only))
      cached = validated_cached_translations
      {
        root:               root,
        source_ref:         source_ref,
        branch:             branch,
        target:             target,
        files:              documents.size,
        classes:            class_inventory(documents.map(&:raw)),
        units:              @units.size,
        cached_units:       cached.size,
        untranslated_units: @units.size - cached.size,
        protected_elements: @protected,
        cache:              cache_path
      }
    end

    def run(only: nil)
      prepare_branch!
      documents = prepare_documents(entries(only: only))
      translations = translate_units
      documents.each_with_index do |document, index|
        rendered = render(document, translations)
        validate_structure!(document.raw, rendered)
        write_document(document, rendered)
        stdout.puts "#{index + 1}/#{documents.size} translated #{document.entry.kind}: #{document.entry.slug}"
      end
      compact_cache!(translations) unless only
      {
        branch: branch, files: documents.size, units: @units.size,
        cached_units: translations.size, cache: cache_path
      }
    end

    private

    def prepare_documents(entries)
      @units.clear
      @protected = 0
      @validated_cached_translations = nil
      entries.map do |entry|
        raw, encoding = read_document(entry.path)
        Document.new(
          entry: entry, template: unitize(raw), encoding: encoding, mode: source_mode(entry.path), raw: raw
        )
      end
    end

    def translate_units
      translations = validated_cached_translations.dup
      pending = @units.values.reject { |unit| translations.key?(unit.key) }
      return translations if pending.empty?

      FileUtils.mkdir_p(File.dirname(cache_path))
      store = JsonlStore.new(cache_path)
      pending.each_slice(BATCH_SIZE).with_index do |batch, batch_index|
        outputs = Array(
          translator.translate_markup(batch.map(&:prepared), from: source_language, to: target)
        )
        unless outputs.size == batch.size
          raise "translation count mismatch: expected #{batch.size}, got #{outputs.size}"
        end

        batch.zip(outputs).each do |unit, output|
          translation = restore_tokens_with_retries(unit, output)
          translations[unit.key] = translation
          cached_translations[unit.key] = translation
          store.append(key: unit.key, translation: translation, at: Time.now.utc.iso8601)
        end
        stdout.puts "translated batch #{batch_index + 1}: #{translations.size}/#{@units.size} units cached"
      end
      translations
    end
  end
end
