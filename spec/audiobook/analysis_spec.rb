require 'spec_helper'
require_relative '../../lib/audiobook/analysis'

RSpec.describe Audiobook::Analysis do
  def fixture(name) = File.expand_path("../fixtures/audiobook/#{name}", __dir__)

  describe Audiobook::Analysis::Corpus do
    it 'reads from the filename the language nothing else can tell us yet' do
      expect(described_class.language_for('1908kybalion.pdf')).to eq('en')
      expect(described_class.language_for('Salud Prohibida.pdf')).to eq('es')
      expect(described_class.language_for('Nao comecou com voce.pdf')).to eq('pt')
    end

    it 'clamps a page range to the pages the book actually has' do
      path = fixture('adios-one-line-paragraphs.pdf')

      expect(described_class.pages_for(path, '1-80')).to eq('1-3')
      expect(described_class.pages_for(path, '1-2')).to eq('1-2')
      expect(described_class.pages_for(path, nil)).to be_nil
    end
  end

  describe Audiobook::Analysis::Detectors do
    let(:book) { Audiobook::Analysis::Corpus.open(fixture('adios-one-line-paragraphs.pdf')) }

    it 'reports where a book set one sentence to the paragraph reads short' do
      hits = described_class.hits(book)

      expect(hits[:tiny]).not_to be_empty
      expect(hits[:quote_start].map(&:last)).to all(start_with('"'))
    end

    it 'tells a sentence that opens its paragraph from one that closes it' do
      opening, closing = described_class.spoken(book).map(&:last).partition(&:opens)

      expect(opening).not_to be_empty
      expect(closing.none?(&:opens)).to be(true)
      expect(described_class.spoken(book).map(&:last)).to all(satisfy { |at| at.page.positive? })
    end

    it 'names the detectors that count correct assembly as often as a defect' do
      expect(described_class::NOISY).to all(satisfy { |name| described_class.names.include?(name) })
    end
  end

  describe Audiobook::Analysis::Report do
    let(:report) { described_class.for(fixture('tragedia-indented-verse.pdf')) }

    it 'counts what the summary compares' do
      counts = report.counts

      expect(counts.keys).to include(*Audiobook::Analysis::Detectors.names)
      expect(counts[:sentences]).to be_positive
      expect(counts[:paras]).to be_positive
      expect(counts[:levels]).to be_positive
    end

    it 'writes the assembled book beside the report so a count can be read back' do
      Dir.mktmpdir do |dir|
        report.write(dir)

        expect(File.read(File.join(dir, "#{report.name}.issues.md"))).to include('# tragedia-indented-verse')
        expect(YAML.unsafe_load_file(File.join(dir, "#{report.name}.yml"))['pages']).not_to be_empty
      end
    end
  end

  describe Audiobook::Analysis::Summary do
    let(:rows) { [['one', { lower_start: 3, paras: 10 }], ['two', { lower_start: 1, paras: 4 }]] }

    it 'round-trips a table of counts' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'summary.tsv')
        File.write(path, described_class.tsv(rows))

        expect(described_class.read(path)['one']).to eq('lower_start' => 3.0, 'paras' => 10.0)
        expect(described_class.totals(path)).to eq('lower_start' => 4.0, 'paras' => 14.0)
      end
    end

    it 'says what a change did, and marks the counts that are noisy' do
      Dir.mktmpdir do |dir|
        before = File.join(dir, 'before.tsv')
        after  = File.join(dir, 'after.tsv')
        File.write(before, described_class.tsv(rows))
        File.write(after, described_class.tsv([['one', { lower_start: 5, paras: 6 }], ['two', rows.last.last]]))

        expect(described_class.diff(before, after)).to include(
          a_string_matching(/lower_start\s+4 → 6\s+\+2 \(noisy\)/),
          a_string_matching(/paras\s+14 → 10\s+-4\z/)
        )
        expect(described_class.per_book(before, after).join).to include('one', 'lower_start 3→5')
      end
    end
  end

  describe Audiobook::Analysis::Breaks do
    it 'explains each break by what the page showed' do
      tally = described_class.tally(fixture('savin-mid-paragraph-sentences.pdf'))

      expect(tally.breaks).to be_positive
      expect(tally.geometry).to be_positive
      expect(tally.unexplained).to eq(0)
    end

    it 'leaves the assembly alone once the caller stops watching' do
      described_class.tally(fixture('tragedia-indented-verse.pdf'))

      expect(Audiobook::Paragraph::Detector.observer).to be_nil
    end
  end
end
