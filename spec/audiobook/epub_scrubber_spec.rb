require 'rails_helper'

RSpec.describe Audiobook::EpubScrubber do
  let(:dir)   { Dir.mktmpdir }
  let(:src)   { File.join(dir, 'book.epub') }
  let(:dest)  { File.join(dir, 'clean.epub') }
  let(:stamp) { "<p style='text-align:left;'>Book made for someone@mail.com</p>" }

  after { FileUtils.remove_entry dir }

  def build_epub(*chapters)
    root = File.join(dir, 'root')
    FileUtils.mkdir_p File.join(root, 'OEBPS')
    File.write File.join(root, 'mimetype'), 'application/epub+zip'
    chapters.each_with_index { |body, i| File.write File.join(root, 'OEBPS', "c#{i}.xhtml"), "<html><body>\n<p>Text #{i}</p>\n\t#{body}</body></html>" }
    Sh.run %W[zip -q -X0 #{src} mimetype], chdir: root
    Sh.run %W[zip -q -X9 -D -r #{src} . -x mimetype], chdir: root
  end

  def read(name) = Sh.run(%W[unzip -p #{dest} #{name}]).first

  it 'removes the stamped paragraph from every chapter and keeps the mimetype first' do
    build_epub(stamp, stamp, '')

    expect(described_class.call(src, dest)).to eq 2
    expect(read('OEBPS/c0.xhtml')).to eq "<html><body>\n<p>Text 0</p>\n</body></html>"
    expect(read('OEBPS/c1.xhtml')).not_to include 'someone@mail.com'
    expect(Sh.run(%W[unzip -Z1 #{dest}]).first.lines.first.strip).to eq 'mimetype'
  end

  it 'leaves the destination unwritten when there is nothing to remove' do
    build_epub('')

    expect(described_class.call(src, dest)).to eq 0
    expect(File).not_to exist dest
  end

  it 'refuses a stamp it cannot remove as a whole paragraph' do
    build_epub('<div>Book made for someone@mail.com</div>')

    expect { described_class.call(src, dest) }.to raise_error(/stamp still present/)
  end
end
