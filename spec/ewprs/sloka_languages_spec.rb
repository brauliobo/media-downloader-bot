require 'json'
require 'tmpdir'
require_relative '../../lib/ewprs/sloka_languages'

RSpec.describe Ewprs::SlokaLanguages do
  let(:sanskrit) { '<p class="Para_Sloka">Sarve bhavantu sukhinah.<br>Oṋḿ shántih.</p>' }
  let(:bengali)  { '<p class=Para_Sloka lang="sa">Tumi kemon kare gán karo he.</p>' }

  it 'adds and corrects language attributes without changing paragraph content' do
    Dir.mktmpdir do |dir|
      manifest = File.join(dir, 'languages.json')
      File.write(manifest, JSON.generate(
        described_class.digest(sanskrit) => 'sa',
        described_class.digest(bengali) => 'bn'
      ))
      html = File.join(dir, 'sample.html')
      File.binwrite(html, "#{sanskrit}\n#{bengali}\n")
      annotator = described_class.new(manifest: manifest)

      stats = annotator.annotate_tree(dir)

      expect(stats).to include(files: 1, changed_files: 1, paragraphs: 2)
      expect(stats[:languages]).to eq('bn' => 1, 'sa' => 1)
      expected = (
        "<p class=\"Para_Sloka\" lang=\"sa\">Sarve bhavantu sukhinah.<br>Oṋḿ shántih.</p>\n" \
        "<p class=Para_Sloka lang=\"bn\">Tumi kemon kare gán karo he.</p>\n"
      )
      expect(File.binread(html)).to eq(expected.b)
      expect(annotator.annotate_tree(dir)).to include(changed_files: 0)
    end
  end

  it 'fails when a verse has no reviewed classification' do
    Dir.mktmpdir do |dir|
      manifest = File.join(dir, 'languages.json')
      File.write(manifest, '{}')
      File.binwrite(File.join(dir, 'sample.html'), sanskrit)

      expect do
        described_class.new(manifest: manifest).annotate_tree(dir)
      end.to raise_error(RuntimeError, /unclassified Para_Sloka/)
    end
  end
end
