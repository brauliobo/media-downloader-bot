module Replay
  # Fills in the language of the books the bot read without one: the yml it posted for each says which language it took. A
  # book whose language differs from the group's default is flagged (`lang_check.mismatch`) to be reprocessed later.
  class LangCheck
    LANG = /\Alang=(.+)\z/

    def initialize(manager) = @manager = manager

    # Returns how many items got their language.
    def call(job)
      expected = lang_in(ChatSetting.default_options(job.options[:chat_id]))
      JobItem.done.where(job_id: job.id).exclude(Sequel.pg_jsonb_op(:result).has_key?('lang_check')).all.count { |item| missing?(item) && fill(item, expected) }
    end

    private

    def lang_in(tokens) = tokens.filter_map { |token| token[LANG, 1] }.first

    # Neither the options the chat had when the book was read nor the ones typed in its message named a language.
    def missing?(item)
      outcome = item.outcome
      lang_in(outcome[:options].to_s.split).nil? && Array(outcome.dig(:input, :inputs)).none? { |input| input.dig(:opts, :lang) }
    end

    def fill(item, expected)
      lang = yml_language(item) or return
      first, *rest = Array(item.outcome.dig(:input, :inputs)).presence || [{}]
      first = first.merge(opts: first.fetch(:opts, {}).merge(lang: lang))
      item.update(result: item.outcome.deep_merge(input: { inputs: [first, *rest] }, lang_check: { lang: lang, expected: expected, mismatch: (lang != expected if expected) }.compact))
    end

    def yml_language(item)
      item.messages_dataset.live.where(kind: 'Document').each do |message|
        media = @manager.chat_message(chat_id: message.chat_id, message_id: message.message_id)&.dig(:media)
        next unless media&.dig(:file_name).to_s.end_with?('.yml')

        data = SymMash.new(Audiobook::Yaml.load(@manager.download_file(media[:file_id])))
        return data.metadata&.language || data.language
      end
      nil
    end
  end
end
