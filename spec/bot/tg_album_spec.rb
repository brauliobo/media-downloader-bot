require 'spec_helper'
require_relative '../../lib/bot/tg_bot'

RSpec.describe Bot::TgBot do
  let(:dir) { Dir.mktmpdir('tg-album-') }
  let(:bot) { described_class.new }
  let(:msg) { SymMash.new(chat: {id: 10}, message_id: 20) }
  let(:tg)  { double('tg') }

  after { FileUtils.remove_entry(dir) if Dir.exist?(dir) }

  def upload(name, mime)
    path = File.join(dir, name)
    File.write(path, '')
    SymMash.new(fn_out: path, mime: mime, type: SymMash.new(name: :document))
  end

  it 'sends media groups with caption only on the first item' do
    captured = nil
    bot.tg = tg
    allow(bot).to receive(:throttle!)
    allow(tg).to receive(:send) do |method, **payload|
      captured = payload if method == :send_media_group
      [double(to_h: {message_id: 1})]
    end

    bot.send_album(msg, 'caption', uploads: [upload('1.jpg', 'image/jpeg'), upload('2.jpg', 'image/jpeg')])

    media = JSON.parse(captured[:media])
    expect(media.map { |item| item['type'] }).to eq(%w[photo photo])
    expect(media.first['caption']).to eq('caption')
    expect(media.last).not_to have_key('caption')
  end
end
