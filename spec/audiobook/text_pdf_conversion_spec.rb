require 'rails_helper'

RSpec.describe Audiobook::TextPdf, 'conversion to PDF' do
  let(:dir)  { Dir.mktmpdir('text-pdf-conversion-') }
  let(:path) { File.join(dir, 'book.pt.pdf') }
  let(:ok)   { Struct.new(:success?, :exitstatus).new(true, 0) }
  let(:book) do
    data = SymMash.new(
      metadata: {page_count: 1, language: 'pt', title: 'Livro'},
      opts:     {includeall: true},
      content:  {lines: [{text: 'Olá, mundo.', font_size: 12, page: 1}], images: []},
    )
    Audiobook::Book.new(data: data, opts: SymMash.new(includeall: true), translate: false)
  end
  let(:commands) { [] }

  before do
    allow(Language).to receive(:book_metadata).and_return('lang' => 'pt', 'title' => '', 'author' => '', 'gender' => 'male')
    allow(Sh).to receive(:run) do |command, **options|
      commands << [command, options]
      File.write(path, '%PDF-')
      ['', '', ok]
    end
  end

  after { FileUtils.remove_entry dir }

  def installed(*bins) = allow(Sh).to receive(:which?) { |bin| bins.include?(bin.to_s) }

  def generate = described_class.generate(book, path)

  it 'prints with chromium in a scratch profile when it is installed' do
    installed 'chromium', 'wkhtmltopdf', 'pandoc'

    expect(generate).to eq path

    command, options = commands.sole
    expect(command.first(3)).to eq %w[chromium --headless --disable-gpu]
    expect(command).to include("--print-to-pdf=#{path}")
    expect(options[:env].keys).to eq %w[XDG_CONFIG_HOME XDG_CACHE_HOME]
  end

  it 'tries the other chromium names in turn' do
    installed 'google-chrome'

    generate

    expect(commands.sole.first.first).to eq 'google-chrome'
  end

  it 'falls back to wkhtmltopdf' do
    installed 'wkhtmltopdf', 'pandoc'

    generate

    command, = commands.sole
    expect(command.first).to eq 'wkhtmltopdf'
    expect(command).to include('A4')
    expect(command.last).to eq path
  end

  it 'falls back to pandoc' do
    installed 'pandoc'

    generate

    command, = commands.sole
    expect(command.first(5)).to eq %w[pandoc -f html -t pdf]
    expect(command).to include('-o', path)
  end

  it 'needs one of the tools' do
    installed

    expect { generate }.to raise_error(RuntimeError, /No PDF generation tool available/)
  end

  it 'reports a failed conversion' do
    installed 'wkhtmltopdf'
    allow(Sh).to receive(:run).and_return(['', 'cannot render', Struct.new(:success?, :exitstatus).new(false, 1)])

    expect { generate }.to raise_error(Sh::Error, /wkhtmltopdf: cannot render/)
  end
end
