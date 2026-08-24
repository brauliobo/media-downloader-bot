require 'spec_helper'
require_relative '../../lib/bot/caption'

RSpec.describe Bot::Caption do
  it 'normalizes escaped Markdown URLs without dropping the protocol' do
    caption = 'https:\/\/example\.com\/photo?id=1'

    expect(described_class.normalize(caption, parse_mode: 'MarkdownV2')).to eq('https://example.com/photo?id=1')
  end

  it 'keeps captions within the media limit' do
    expect(described_class.prepare('ok', parse_mode: 'MarkdownV2')).to eq('ok')
  end

  it 'removes Bot API punctuation escapes for TDLib' do
    caption = '_Novembro de 2025\. \-19 – 20 mg\/day  Ivermectin\/I\? \"ok\"_'

    expect(described_class.prepare(caption, parse_mode: 'MarkdownV2')).to eq(
      '_Novembro de 2025. -19 – 20 mg/day  Ivermectin/I? "ok"_'
    )
  end

  it 'keeps escaped formatting markers' do
    caption = '_A \_literal\_ marker and \*stars\*_'

    expect(described_class.prepare(caption, parse_mode: 'MarkdownV2')).to eq(caption)
  end

  it 'yields overflow text then returns a truncated media caption' do
    text     = 'a' * (described_class::MEDIA_LIMIT + 1)
    overflow = nil
    caption  = described_class.prepare(text, parse_mode: 'MarkdownV2') { |full| overflow = full }

    expect(overflow).to eq(text)
    expect(caption).to eq(text.first(described_class::MEDIA_LIMIT))
  end

  it 'closes truncated italic captions' do
    caption   = "_#{'a' * described_class::MEDIA_LIMIT}_"
    truncated = described_class.truncate(caption)

    expect(truncated.size).to eq(described_class::MEDIA_LIMIT)
    expect(truncated).to end_with('_')
    expect(truncated.scan(/(?<!\\)_/).size).to be_even
  end

  it 'preserves trailing links when truncating captions' do
    url       = 'x\.com\/i\/status\/2073169414275350804'
    caption   = "_#{'a' * described_class::MEDIA_LIMIT}_\n\n#{url}"
    overflow  = nil
    truncated = described_class.prepare(caption, parse_mode: 'MarkdownV2') { |full| overflow = full }

    expect(overflow).to eq("_#{'a' * described_class::MEDIA_LIMIT}_\n\nx.com/i/status/2073169414275350804")
    expect(truncated.size).to be <= described_class::MEDIA_LIMIT
    expect(truncated).to end_with('x.com/i/status/2073169414275350804')
    expect(truncated.scan(/(?<!\\)_/).size).to be_even
  end
end
