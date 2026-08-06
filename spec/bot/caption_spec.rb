require 'spec_helper'
require_relative '../../lib/bot/caption'

RSpec.describe Bot::Caption do
  it 'normalizes escaped Markdown URLs without dropping the protocol' do
    caption = 'https:\/\/example\.com\/photo?id=1'

    expect(described_class.normalize(caption, parse_mode: 'MarkdownV2')).to eq('https://example.com/photo?id=1')
  end
end
