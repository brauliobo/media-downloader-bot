require 'rails_helper'

RSpec.describe Audiobook::Outline do
  it 'nests the headings that follow a chapter under it' do
    chapter = Audiobook::Heading.new('One').tap { |heading| heading.role = :chapter }
    page    = Audiobook::Page.new(3, [chapter, Audiobook::Heading.new('Sub')])

    expect(described_class.build([page])).to eq(
      [{ 'text' => 'One', 'page' => 3, 'role' => 'chapter', 'headings' => [{ 'text' => 'Sub', 'page' => 3 }] }]
    )
  end

  it 'lists headings that open no chapter on their own' do
    page = Audiobook::Page.new(1, [Audiobook::Heading.new('Preface')])

    expect(described_class.build([page])).to eq([{ 'text' => 'Preface', 'page' => 1 }])
  end
end
