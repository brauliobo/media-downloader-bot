require 'fileutils'
require 'json'
require 'time'

require_relative '../../jsonl_store'

module Ewprs
  class TranslationBatch
    module CacheManagement
      include TranslationMarkup

      private

      def cached_translations
        @cached_translations ||= JsonlStore.new(cache_path).each_with_object({}) do |record, values|
          values[record.fetch(:key)] = preserve_entities(record.fetch(:translation))
        end
      end

      def validated_cached_translations
        @validated_cached_translations ||= @units.each_with_object({}) do |(key, unit), values|
          translation = cached_translations[key]
          next unless translation

          begin
            unless cached_nested_markers_valid?(unit, translation)
              raise TranslationValidator::Error.new(
                :nested_units, 'translation has stale nested unit markers'
              )
            end

            translation = validate_restored_translation!(unit, translation)
            values[key] = translation
            cached_translations[key] = translation
          rescue TranslationValidator::Error => error
            stdout.puts "discarding invalid cached translation #{key}: #{error.message}"
          end
        end
      end

      def compact_cache!(translations)
        FileUtils.mkdir_p(File.dirname(cache_path))
        temp = "#{cache_path}.tmp"
        timestamp = Time.now.utc.iso8601
        File.open(temp, 'w') do |file|
          @units.each_key do |key|
            file.puts JSON.generate(key: key, translation: translations.fetch(key), at: timestamp)
          end
          file.flush
          file.fsync
        end
        File.rename(temp, cache_path)
      ensure
        FileUtils.rm_f(temp) if temp && File.exist?(temp)
      end

      def resolve_nested_translation(value, seen = {})
        value.gsub(UNIT_MARKER) do |marker|
          key = Regexp.last_match(1)
          next marker if seen.key?(key) || !cached_translations.key?(key)

          resolve_nested_translation(cached_translations.fetch(key), seen.merge(key => true))
        end
      end
    end
  end
end
