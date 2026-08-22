require 'spec_helper'

RSpec.describe Audiobook::Paragraph::Factory do
  def line(text, size, **style)
    Audiobook::Line.new(text, font_size: size, page_number: 1, **style)
  end

  def items_from(*lines)
    roles = Audiobook::FontRoles.from_lines(lines)
    Audiobook::FontRoles.use(roles) { described_class.create_items_from_lines(lines, 1) }.map { |entry| entry[:item] }
  end

  it 'merges multiline headings that share a font size' do
    items = items_from(
      line('THE HIDDEN', 18, bold: true, alignment: :center),
      line('KINGDOM', 18, bold: true, alignment: :center),
      line('A body paragraph that stays body because it has enough words in it.', 12),
      line('Another body paragraph continues the story with more words here.', 12)
    )

    heading = items.grep(Audiobook::Heading).first || items.grep(Audiobook::Section).first
    expect(heading.text).to eq('THE HIDDEN KINGDOM')
    expect(items.grep(Audiobook::Paragraph).map { |para| para.sentences.map(&:text).join(' ') }.join(' '))
      .not_to include('THE HIDDEN')
  end

  it 'merges heading sentences that share a font size' do
    items = items_from(
      line('The Hidden Kingdom.', 18, bold: true, alignment: :center),
      line('A Forgotten Age.', 18, bold: true, alignment: :left),
      line('The story continues with a full paragraph of narrative body text here.', 12),
      line('Another body paragraph continues the story with more words here.', 12),
      line('More body text so twelve point remains the dominant size overall.', 12)
    )

    heading = items.grep(Audiobook::Heading).first || items.grep(Audiobook::Section).first
    expect(heading.text).to eq('The Hidden Kingdom. A Forgotten Age.')
    expect(items.grep(Audiobook::Paragraph).first.sentences.map(&:text).join(' ')).to include('The story continues')
  end

  it 'does not merge labeled cover lines into a title heading' do
    items = items_from(
      line('HE - A CHAVE DO ENTENDIMENTO DA PSICOLOGIA MASCULINA', 16, bold: true, alignment: :center),
      line('AUTOR: ROBERT A. JOHNSON', 16, bold: true, alignment: :center),
      line('EDITORA: MERCURYO', 16, bold: true, alignment: :center),
      line('The story continues with a full paragraph of narrative body text here.', 12),
      line('Another body paragraph continues the story with more words here.', 12)
    )
    texts = items.map { |item| item.respond_to?(:text) ? item.text : item.sentences.map(&:text).join(' ') }

    expect(texts).to include('HE - A CHAVE DO ENTENDIMENTO DA PSICOLOGIA MASCULINA')
    expect(texts.join(' ')).to include('AUTOR: ROBERT A. JOHNSON')
    expect(texts).not_to include(
      'HE - A CHAVE DO ENTENDIMENTO DA PSICOLOGIA MASCULINA AUTOR: ROBERT A. JOHNSON EDITORA: MERCURYO'
    )
  end

  it 'does not merge a heading with the following body of a different size' do
    items = items_from(
      line('CHAPTER ONE', 18, bold: true, alignment: :center),
      line('The story continues with a full paragraph of narrative body text here.', 12)
    )

    heading = items.grep(Audiobook::Heading).first || items.grep(Audiobook::Section).first
    paragraph = items.grep(Audiobook::Paragraph).first
    expect(heading.text).to eq('CHAPTER ONE')
    expect(paragraph.sentences.map(&:text).join(' ')).to include('The story continues')
  end

  it 'discovers a multiline heading across finished sentences of the same font' do
    lines = [
      line('The Hidden Kingdom.', 18, bold: true, alignment: :center),
      line('A Forgotten Age.', 18, bold: true, alignment: :left),
      line('The story continues with a full paragraph of narrative body text here.', 12),
      line('Another body paragraph continues the story with more words here.', 12),
    ]
    roles = Audiobook::FontRoles.from_lines(lines)
    items = Audiobook::FontRoles.use(roles) { Audiobook::Paragraph.discover_from_lines(lines) }.map { |entry| entry[:item] }
    heading = items.grep(Audiobook::Heading).first || items.grep(Audiobook::Section).first

    expect(heading.text).to eq('The Hidden Kingdom. A Forgotten Age.')
  end
end
