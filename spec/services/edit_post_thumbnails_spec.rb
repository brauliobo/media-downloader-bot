require 'spec_helper'
require_relative '../../lib/services/edit_post_thumbnails'

RSpec.describe Services::EditPostThumbnails do
  let(:urls) do
    [
      'https://t.me/industria_da_saude/1205',
      'https://t.me/clo2_materiais/290',
    ]
  end

  it 'downloads shared media once and edits every existing post in place' do
    Dir.mktmpdir do |dir|
      thumbnail = File.join(dir, 'cover.jpg')
      source = File.join(dir, 'book.opus')
      File.write(thumbnail, 'cover')
      File.write(source, 'audio')
      manager = double('manager')
      edits = []
      allow(manager).to receive(:chat_message) do |chat_id:, message_id:|
        {
          id: message_id, chat_id: chat_id, text: 'caption',
          media: {kind: 'audio', file_id: 7, remote_id: 'shared', file_name: 'book.opus'},
        }
      end
      expect(manager).to receive(:download_file).once.with(7, dir: kind_of(String)).and_return(source)
      allow(manager).to receive(:edit_generated_message) { |**params| edits << params; {message_id: params[:message_id]} }
      allow(Sh).to receive(:run) do |command|
        expect(command).to include('-c:a copy', '-f mp4')
        File.write(command.split.last, 'm4a')
        ['', '', double(success?: true)]
      end
      chat_ids = {'industria_da_saude' => -1001, 'clo2_materiais' => -1002}

      described_class.new(
        urls: urls, thumbnail: thumbnail, manager: manager,
        resolver: ->(username) { chat_ids.fetch(username) }, output: StringIO.new,
      ).run

      expect(edits.map { |edit| edit[:message_id] }).to eq([1205, 290].map { |id| id * described_class::MESSAGE_ID_FACTOR })
      expect(edits.map { |edit| edit[:chat_id] }).to eq([-1001, -1002])
      expect(edits).to all(include(type: :audio, copy: false))
      expect(edits).to all(satisfy { |edit| !edit.key?(:remote_id) })
      expect(edits.map { |edit| File.basename(edit[:thumbnail_path]) }).to all(eq('cover.jpg'))
      expect(edits.map { |edit| File.extname(edit[:file_path]) }).to all(eq('.m4a'))
      expect(Sh).to have_received(:run).once
    end
  end

  it 'rejects unsupported Telegram URLs before contacting DRb' do
    expect do
      described_class.new(urls: ['https://example.com/post/1'], thumbnail: __FILE__)
    end.to raise_error(ArgumentError, /invalid public Telegram post URL/)
  end
end
