require 'spec_helper'
require 'nokogiri'
require_relative '../../lib/audiobook/parsers/css_style'

RSpec.describe Audiobook::Parsers::CssStyle do
  it 'maps tag, class, and inline CSS onto the generic line style' do
    html = <<~HTML
      <style>
        .chapter { font-size: 22pt; font-weight: bold; text-align: center; color: #112233; font-family: Georgia; }
        p { font-size: 12pt; }
      </style>
      <p class="chapter" style="font-style: italic">Chapter One</p>
    HTML
    doc = Nokogiri::HTML5.parse(html)
    style = described_class.for_node(doc.at('p'), described_class.sheets_from(doc))

    expect(style[:font_size]).to eq(22)
    expect(style[:bold]).to be(true)
    expect(style[:italic]).to be(true)
    expect(style[:alignment]).to eq(:center)
    expect(style[:color]).to eq('#112233')
    expect(style[:font_name]).to eq('Georgia')
  end

  it 'converts px and em sizes relative to the inherited base' do
    expect(described_class.size_to_pt('16px', 12)).to eq(12.0)
    expect(described_class.size_to_pt('1.5em', 12)).to eq(18.0)
    expect(described_class.size_to_pt('x-large', 12)).to eq(18)
  end
end
