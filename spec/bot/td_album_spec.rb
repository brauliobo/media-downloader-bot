require 'spec_helper'

begin
  require_relative '../../lib/bot/td_bot'
  td_load_error = nil
rescue LoadError => e
  td_load_error = e
end

if td_load_error
  RSpec.describe 'Bot::TDBot album support' do
    it 'requires tdlib-ruby' do
      skip td_load_error.message
    end
  end
else

  RSpec.describe Bot::TDBot do
    let(:dir) { Dir.mktmpdir('td-album-') }
    let(:bot) { described_class.new }

    after { FileUtils.remove_entry(dir) if Dir.exist?(dir) }

    it 'builds compact TDLib photo album content with a local input file' do
      path = File.join(dir, 'photo.jpg')
      File.write(path, '')

      file_manager   = double(copy_to_safe_location: path)
      message_sender = double(file_manager: file_manager)
      allow(message_sender).to receive(:parse_markdown_text).and_return('@type' => 'formattedText', 'text' => 'caption', 'entities' => [])
      allow(bot).to receive(:message_sender).and_return(message_sender)

      content = bot.send(:album_content, SymMash.new(fn_out: path, mime: 'image/jpeg'), 'caption', 'MarkdownV2')

      expect(content).to include('@type' => 'inputMessagePhoto')
      expect(content['photo']).to eq('@type' => 'inputPhoto', 'photo' => { '@type' => 'inputFileLocal', 'path' => path })
      expect(content).not_to have_key('thumbnail')
      expect(content).not_to have_key('self_destruct_type')
    end

    it 'wraps TD message objects without passing them to SymMash' do
      message_class = Struct.new(:id) do
        def each_pair = raise('unexpected each_pair')
      end

      expect(bot.send(:td_message_response, message_class.new(123))).to eq(message_id: 123, id: 123)
    end
  end
end
