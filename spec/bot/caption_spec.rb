require 'rails_helper'

RSpec.describe Bot::Caption do
  it 'keeps captions within the media limit' do
    expect(described_class.prepare('ok', parse_mode: 'MarkdownV2')).to eq('ok')
  end

  it 'keeps every escape so TDLib can parse the caption' do
    caption = '_Com que frequência\? \(EXPERIMENTO\)_' + "\n\nyoutu\\.be\\/wI2WVevL\\_lk"

    expect(described_class.prepare(caption, parse_mode: 'MarkdownV2')).to eq(caption)
  end

  it 'counts escaped characters once against the media limit' do
    caption = '\.' * described_class::MEDIA_LIMIT

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

    expect(overflow).to eq(caption)
    expect(truncated.size).to be <= described_class::MEDIA_LIMIT
    expect(truncated).to end_with(url)
    expect(truncated.scan(/(?<!\\)_/).size).to be_even
  end
end
