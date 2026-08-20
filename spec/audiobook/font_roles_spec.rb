require 'spec_helper'
require_relative '../../lib/audiobook/font_roles'
require_relative '../../lib/audiobook/line'

RSpec.describe Audiobook::FontRoles do
  def line(text, size, **style)
    Audiobook::Line.new(text, font_size: size, **style)
  end

  it 'maps larger sizes to chapter then heading and keeps body as the mode' do
    roles = described_class.from_lines([
      line('Title', 24, bold: true, alignment: :center),
      line('Chapter One', 18, bold: true, alignment: :center),
      line('Chapter Two', 18, bold: true, alignment: :center),
      line('Body one is long enough.', 12),
      line('Body two is long enough.', 12),
      line('Body three is long enough.', 12),
      line('Body four is long enough.', 12),
    ])

    expect(roles.body_size).to eq(12.0)
    expect(roles.role_for(line('Title', 24, bold: true, alignment: :center))).to eq(:title)
    expect(roles.level_for(line('Chapter One', 18, bold: true, alignment: :center))).to eq(1)
    expect(roles.role_for(12)).to eq(:body)
  end

  it 'promotes bold centered body-sized lines when they are the minority' do
    roles = described_class.from_lines([
      line('A Short Heading', 12, bold: true, alignment: :center),
      line('Body one is long enough.', 12),
      line('Body two is long enough.', 12),
      line('Body three is long enough.', 12),
      line('Body four is long enough.', 12),
    ])

    heading = line('A Short Heading', 12, bold: true, alignment: :center)
    expect(roles.heading?(heading)).to be(true)
    expect(roles.heading?(line('Body one is long enough.', 12))).to be(false)
  end

  it 'round-trips the role map through hashes' do
    roles = described_class.from_lines([
      line('Title', 24, bold: true, alignment: :center),
      line('Chapter One', 18, bold: true, alignment: :center),
      line('Chapter Two', 18, bold: true, alignment: :center),
      line('Body one is long enough.', 12),
      line('Body two is long enough.', 12),
      line('Body three is long enough.', 12),
      line('Body four is long enough.', 12),
    ])
    restored = described_class.from_h(roles.to_h)

    expect(restored.body_size).to eq(12.0)
    expect(restored.role_for(line('Title', 24, bold: true, alignment: :center))).to eq(:title)
    expect(restored.level_for(line('Chapter One', 18, bold: true, alignment: :center))).to eq(1)
  end

  it 'derives center alignment from page coordinates' do
    expect(described_class.alignment_for(x: 200, x_max: 400, page_width: 600)).to eq(:center)
    expect(described_class.alignment_for(x: 40, x_max: 400, page_width: 600)).to eq(:left)
    expect(described_class.alignment_for(x: 400, x_max: 560, page_width: 600)).to eq(:right)
  end
end
