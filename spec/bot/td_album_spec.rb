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

    before { allow(bot).to receive(:throttle!) }
    after { FileUtils.remove_entry(dir) if Dir.exist?(dir) }

    it 'accepts TDLib 1.8.65 link preview photos without an author' do
      wrapped = TD::Types.wrap(
        '@type' => 'linkPreviewTypePhoto',
        'photo' => {'@type' => 'photo', 'has_stickers' => false, 'minithumbnail' => nil, 'sizes' => []},
      )

      expect(wrapped.author).to eq('')
    end

    it 'delegates album sending to tdlib-ruby message sender' do
      path = File.join(dir, 'photo.jpg')
      File.write(path, '')

      msg            = SymMash.new(chat: {id: 123})
      upload         = SymMash.new(fn_out: path, mime: 'image/jpeg')
      message        = double(id: 456)
      message_sender = double(send_media_album: [message])
      allow(bot).to receive(:message_sender).and_return(message_sender)
      allow(bot).to receive(:finalize_sent_message)

      expect(bot.send_album(msg, 'caption', uploads: [upload])).to eq([message])
      expect(message_sender).to have_received(:send_media_album).with(
        123, [upload], caption: 'caption', parse_mode: 'MarkdownV2', timeout: 1_800
      )
      expect(bot).to have_received(:throttle!).with(no_args)
    end

    it 'builds generated audio with the TDLib inputMessageAudio shape' do
      path    = File.join(dir, 'audiobook.opus')
      caption = {'@type' => 'formattedText', 'text' => 'Caption', 'entities' => []}
      File.write(path, '')
      allow(bot.message_sender).to receive(:parse_markdown_text).with('Caption', nil).and_return(caption)

      content = bot.post_editor.send(
        :generated_message_content, 'audio', 'Caption', nil,
        audio_path: path, duration: 34, title: 'Title', performer: 'Performer', copy: false
      )

      expect(content).to eq(
        '@type'   => 'inputMessageAudio',
        'audio'   => {
          '@type'                 => 'inputAudio',
          'audio'                 => {'@type' => 'inputFileLocal', 'path' => path},
          'album_cover_thumbnail' => nil,
          'duration'              => 34,
          'title'                 => 'Title',
          'performer'             => 'Performer'
        },
        'caption' => caption
      )
    end

    it 'sends generated media to a typed forum topic' do
      td      = double('TD::Client')
      future  = double('future')
      message = double(id: 456)
      allow(bot).to receive(:td).and_return(td)
      allow(td).to receive(:send_message).and_return(future)
      allow(future).to receive(:value!).with(30).and_return(message)

      result = bot.post_editor.send(:send_message_content, 123, 42, {'@type' => 'inputMessageText'}, 30)

      expect(result).to be(message)
      expect(td).to have_received(:send_message) do |args|
        expect(args[:topic_id]).to be_a(TD::Types::MessageTopicForum)
        expect(args[:topic_id].forum_topic_id).to eq(42)
        expect(args).not_to have_key(:message_thread_id)
      end
    end

    it 'sends full long album captions as text and keeps a truncated media caption' do
      text = 'a' * (described_class::MEDIA_CAPTION_LIMIT + 1)
      msg  = SymMash.new(chat: {id: 123})
      allow(bot).to receive(:send_message)

      expect(bot.album_caption_text(msg, text, 'MarkdownV2')).to eq(text.first(described_class::MEDIA_CAPTION_LIMIT))
      expect(bot).to have_received(:send_message).with(msg, text, parse_mode: 'MarkdownV2')
    end

    it 'removes Bot API punctuation escapes before sending TDLib album captions' do
      caption = '_Novembro de 2025\. \-19 – 20 mg\/day  Ivermectin\/I\? \"ok\"_'

      expect(bot.album_caption_text(SymMash.new(chat: {id: 123}), caption, 'MarkdownV2')).to eq(
        '_Novembro de 2025. -19 – 20 mg/day  Ivermectin/I? "ok"_'
      )
    end

    it 'keeps escaped formatting markers in TDLib album captions' do
      caption = '_A \_literal\_ marker and \*stars\*_'

      expect(bot.album_caption_text(SymMash.new(chat: {id: 123}), caption, 'MarkdownV2')).to eq(caption)
    end

    it 'closes truncated italic TDLib album captions' do
      caption = "_#{'a' * described_class::MEDIA_CAPTION_LIMIT}_"
      allow(bot).to receive(:send_message)

      truncated = bot.album_caption_text(SymMash.new(chat: {id: 123}), caption, 'MarkdownV2')

      expect(truncated.size).to eq(described_class::MEDIA_CAPTION_LIMIT)
      expect(truncated).to end_with('_')
      expect(truncated.scan(/(?<!\\)_/).size).to be_even
    end

    it 'preserves trailing links when truncating TDLib album captions' do
      url     = 'https:\/\/x\.com\/i\/status\/2073169414275350804'
      caption = "_#{'a' * described_class::MEDIA_CAPTION_LIMIT}_\n\n#{url}"
      msg     = SymMash.new(chat: {id: 123})
      allow(bot).to receive(:send_message)

      truncated = bot.album_caption_text(msg, caption, 'MarkdownV2')

      expect(truncated.size).to be <= described_class::MEDIA_CAPTION_LIMIT
      expect(truncated).to end_with('https://x.com/i/status/2073169414275350804')
      expect(truncated.scan(/(?<!\\)_/).size).to be_even
      expect(bot).to have_received(:send_message).with(
        msg,
        "_#{'a' * described_class::MEDIA_CAPTION_LIMIT}_\n\nhttps://x.com/i/status/2073169414275350804",
        parse_mode: 'MarkdownV2'
      )
    end

    it 'delegates long album sending with a truncated media caption' do
      path = File.join(dir, 'photo.jpg')
      File.write(path, '')

      msg            = SymMash.new(chat: {id: 123})
      text           = 'a' * (described_class::MEDIA_CAPTION_LIMIT + 1)
      upload         = SymMash.new(fn_out: path, mime: 'image/jpeg')
      message        = double(id: 456)
      message_sender = double(send_media_album: [message])
      allow(bot).to receive(:message_sender).and_return(message_sender)
      allow(bot).to receive(:send_message)
      allow(bot).to receive(:finalize_sent_message)

      bot.send_album(msg, text, uploads: [upload])

      expect(bot).to have_received(:send_message).with(msg, text, parse_mode: 'MarkdownV2')
      expect(message_sender).to have_received(:send_media_album).with(
        123, [upload], caption: text.first(described_class::MEDIA_CAPTION_LIMIT), parse_mode: 'MarkdownV2', timeout: 1_800
      )
    end

    it 'wraps TD message objects without passing them to SymMash' do
      message_class = Struct.new(:id) do
        def each_pair = raise('unexpected each_pair')
      end

      expect(bot.send(:td_message_response, message_class.new(123))).to eq(message_id: 123, id: 123)
    end
  end
end
