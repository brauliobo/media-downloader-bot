require 'rails_helper'
require 'open3'

RSpec.describe Audiobook::Parsers::Pdf do
  def fixture_path(name)
    File.expand_path("../fixtures/#{name}", __dir__)
  end

  it 'builds the canonical document from real Poppler word boundaries' do
    document = described_class.extract_document(
      fixture_path('image-text-handler.pdf'),
      page_limit: described_class::MAX_PAGES + 1
    )

    expect(document.pages.map(&:number)).to eq([1, 2, 3])
    expect(document.pages.map { |page| page.lines.size }).to eq([0, 20, 7])

    page = document.pages[1]
    expect(page.width).to eq(612)
    expect(page.height).to eq(792)
    expect(page.lines.first.text).to eq('DADOS DE COPYRIGHT')
    expect(page.lines.first.font_size).to be_positive
    expect(page.lines.first.x).to be_positive
    expect(page.lines.first.y).to be_positive
  end

  def words(*specs)
    nodes = specs.map do |text, x_min, x_max, y_min, y_max|
      %(<word xMin="#{x_min}" xMax="#{x_max}" yMin="#{y_min}" yMax="#{y_max}">#{text}</word>)
    end
    Nokogiri::XML("<line>#{nodes.join}</line>").xpath('//word')
  end

  it 'joins small-capital runs and tags raised markers' do
    small_caps = words(['D', 108, 116, 233.1, 245.7], ['ESENVOLVIMENTO', 116, 192, 235.2, 245.2])
    marker     = words(['Troyes.', 85, 233, 288.0, 300.4], ['1', 234, 240, 286.7, 294.5], ['Há', 247, 262, 288.0, 300.4])

    expect(described_class.line_text(small_caps)).to eq('DESENVOLVIMENTO')
    expect(described_class.line_text(marker)).to eq('Troyes.⟦1⟧ Há')
  end

  it 'takes the baseline most words share so a bullet does not raise the rest of the line' do
    bullet = words(['♦', 176, 192, 230.0, 257.0], ['use', 209, 230, 242.0, 254.4], ['8', 235, 242, 242.0, 254.4], ['gotas', 247, 280, 242.0, 254.4])

    expect(described_class.line_text(bullet)).to eq('♦ use 8 gotas')
  end

  it 'tags a run of raised markers one id at a time' do
    run = words(['stressantes.', 85, 233, 288.0, 300.4], ['17,18', 234, 250, 286.7, 294.5], ['O', 254, 262, 288.0, 300.4])

    expect(described_class.line_text(run)).to eq('stressantes.⟦17⟧⟦18⟧ O')
  end

  it 'joins lines of one block that share a baseline' do
    xml = <<~XML
      <doc>
        <page width="612" height="792">
          <block xMin="94" yMin="724" xMax="500" yMax="762">
            <line xMin="94" yMin="724.8" xMax="203" yMax="743.7"><word xMin="94" yMin="724.8" xMax="203" yMax="743.7">possivelmente</word></line>
            <line xMin="233" yMin="724.8" xMax="298" yMax="743.7"><word xMin="233" yMin="724.8" xMax="298" yMax="743.7">começar</word></line>
            <line xMin="94" yMin="742.7" xMax="266" yMax="762.2"><word xMin="94" yMin="742.7" xMax="193" yMax="762.2">positivos</word></line>
          </block>
        </page>
      </doc>
    XML
    status = instance_double(Process::Status, success?: true)
    allow(Sh).to receive(:run).and_return([xml, '', status])
    allow(described_class).to receive(:pdftohtml_bin).and_return(nil)

    pages = described_class.extract_document_range('book.pdf', first_page: 1, last_page: 1)

    expect(pages.first.lines.map(&:text)).to eq(['possivelmente começar', 'positivos'])
    expect(pages.first.lines.first.x_max).to eq(298.0)
  end

  it 'reads a tight justified gap as a space and a small-caps gap as none' do
    justified = words(['So,', 66.1, 79.5, 245.0, 258.9], ['the', 80.6, 95.9, 245.0, 258.9])
    small_cap = words(['J', 108, 116, 233.1, 245.7], ['HONATAN', 116.3, 192, 235.2, 245.2])

    expect(described_class.line_text(justified)).to eq('So, the')
    expect(described_class.line_text(small_cap)).to eq('JHONATAN')
  end

  it 'rejoins one baseline whose words each landed in their own block' do
    xml = <<~XML
      <doc>
        <page width="595" height="842">
          <flow><block xMin="129" yMin="435.4" xMax="159" yMax="450.8">
            <line xMin="129.9" yMin="435.4" xMax="159.5" yMax="450.8"><word xMin="129.9" yMin="435.4" xMax="159.5" yMax="450.8">dias,</word></line>
          </block></flow>
          <flow><block xMin="173" yMin="435.4" xMax="208" yMax="450.8">
            <line xMin="173.6" yMin="435.4" xMax="208.7" yMax="450.8"><word xMin="173.6" yMin="435.4" xMax="208.7" yMax="450.8">estou</word></line>
          </block></flow>
          <flow><block xMin="129" yMin="455.0" xMax="200" yMax="470.4">
            <line xMin="129.9" yMin="455.0" xMax="200.0" yMax="470.4"><word xMin="129.9" yMin="455.0" xMax="200.0" yMax="470.4">certo</word></line>
          </block></flow>
        </page>
      </doc>
    XML
    status = instance_double(Process::Status, success?: true)
    allow(Sh).to receive(:run).and_return([xml, '', status])
    allow(described_class).to receive(:pdftohtml_bin).and_return(nil)

    pages = described_class.extract_document_range('book.pdf', first_page: 1, last_page: 1)

    expect(pages.first.lines.map(&:text)).to eq(['dias, estou', 'certo'])
  end

  it 'leaves a contents entry apart from the folio it points at' do
    far = [
      Nokogiri::XML('<line><word xMin="94" xMax="240" yMin="48" yMax="62">PREFÁCIO</word></line>').xpath('//word'),
      Nokogiri::XML('<line><word xMin="508" xMax="516" yMin="48" yMax="62">10</word></line>').xpath('//word'),
    ]

    expect(described_class.side_by_side?(far.first.to_a, far.last.to_a)).to be(false)
  end

  it 'sizes a line from its body words, ignoring raised markers' do
    line = words(['Troyes.', 85, 233, 288.0, 300.4], ['1', 234, 240, 286.7, 294.5], ['Há', 247, 262, 288.0, 300.4])

    expect(described_class.line_font_size(line, described_class.word_baseline(line))).to be_within(0.01).of(12.4)
  end

  it 'takes the nominal font size so tall glyphs do not split a paragraph' do
    data      = described_class.extract_data(fixture_path('audiobook/salud-softhyphen-font-metrics.pdf'))
    body      = data.content.lines.map { |line| line.font_size.round(1) }.tally.max_by { |_, count| count }.first
    stretched = data.content.lines.select { |line| line.text.match?(/respuesta fue sim|Le hice caso/) }

    expect(stretched.size).to eq(2)
    expect(stretched.map { |line| line.font_size.round(1) }.uniq).to eq([body])
  end

  it 'routes only a real image-only page to OCR' do
    data = described_class.extract_data(fixture_path('image-text-handler.pdf'))

    expect(data.metadata.page_count).to eq(3)
    expect(data.metadata.title).to eq('image-text-handler')
    expect(data.metadata.has_ocr_pages).to eq(true)
    expect(data.content.images.map(&:page)).to eq([1])
    expect(data.content.lines.map(&:page).uniq).to eq([2, 3])
    expect(data.content.lines.first.text).to eq('DADOS DE COPYRIGHT')
  end

  it 'preserves words, references, and geometry from a real text PDF' do
    data = described_class.extract_data(fixture_path('page-paragraphs-merge.pdf'))
    line = data.content.lines.find { |item| item.text.include?('Chrétien de Troyes') }

    expect(data.metadata.page_count).to eq(4)
    expect(data.content.images).to be_empty
    expect(line.text).to include('Chrétien de Troyes.⟦1⟧')
    expect(line.text).to include('Wolfram von Eschenbach⟦2⟧')
    expect(line.bottom_spacing).to be_a(Numeric)
    expect(line.x).to be_positive
  end

  it 'reads pdfinfo author as a hint without treating it as the spoken author' do
    status = instance_double(Process::Status, success?: true)
    allow(Sh).to receive(:run).with(['pdfinfo', 'book.pdf']).and_return([
      "Title:           A Solução Mineral Mestre\nAuthor:          GENESIS 2 CHURCH\nPages:           10\n",
      '',
      status,
    ])

    info = described_class.extract_pdfinfo('book.pdf')

    expect(info.title).to eq('A Solução Mineral Mestre')
    expect(info.author).to eq('GENESIS 2 CHURCH')
    expect(info.pages).to eq(10)
  end

  it 'parses pdftotext bbox XML that contains XML 1.0 illegal control bytes' do
    xml = <<~XML
      <doc>
        <page width="612" height="792">
          <line yMin="10" yMax="20" xMin="10" xMax="100">
            <word yMin="10" yMax="20" xMin="10" xMax="50">condiç#{1.chr}#{3.chr}#{2.chr}</word>
            <word yMin="10" yMax="20" xMin="55" xMax="90">normal</word>
          </line>
        </page>
      </doc>
    XML
    status = instance_double(Process::Status, success?: true)
    allow(Sh).to receive(:run).and_return([xml, '', status])
    allow(described_class).to receive(:pdftohtml_bin).and_return(nil)

    pages = described_class.extract_document_range('book.pdf', first_page: 1, last_page: 1)

    expect(pages.first.lines.first.text).to eq("condiç normal")
  end

  it 'extracts style from a copy-restricted PDF' do
    Dir.mktmpdir do |dir|
      restricted = File.join(dir, 'restricted.pdf')
      _out, stderr, status = Open3.capture3(
        'qpdf', '--encrypt', '', '', '256', '--extract=n', '--print=full', '--modify=none', '--',
        fixture_path('page-paragraphs-merge.pdf'), restricted
      )
      raise "qpdf encrypt failed: #{stderr}" unless status.success?

      data = described_class.extract_data(restricted)
      expect(data.content.lines).not_to be_empty
      expect(data.content.lines.first.text).to be_present
    end
  end

  it 'limits the real Poppler extraction to the requested page range' do
    document = described_class.extract_document(
      fixture_path('image-text-handler.pdf'),
      page_limit: 2
    )

    expect(document.pages.map(&:number)).to eq([1, 2])
  end

  it 'extracts only selected disjoint page ranges with original page numbers' do
    data = described_class.extract_data(
      fixture_path('image-text-handler.pdf'),
      opts: SymMash.new(pages: '1,3')
    )

    expect(data.metadata.page_count).to eq(3)
    expect(data.metadata.selected_pages).to eq([1, 3])
    expect(data.content.images.map(&:page)).to eq([1])
    expect(data.content.lines.map(&:page).uniq).to eq([3])
  end
end
