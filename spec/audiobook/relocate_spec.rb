require 'rails_helper'

RSpec.describe Audiobook, '.relocate_file' do
  let(:title) { 'Livro de Exercícios para Reconfigurar o Nervo Vago: Guia para Iniciantes sobre a Teoria Polivagal e Exercícios Somáticos Simples para Acalmar Ansiedade, Estresse, Depressão e Trauma, além de Melhorar o Sono, a Digestão e a Saúde do Sistema Nervoso' }

  it 'names a file after a title longer than a file name can be' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'book.yml')
      File.write(path, 'x')
      base = described_class.safe_filename("#{title} - Lulu Nicholson")

      moved = described_class.relocate_file(path, "#{base}.yml")

      expect(File.file?(moved)).to be(true)
      expect(File.basename(moved).bytesize).to be <= 255
    end
  end
end
