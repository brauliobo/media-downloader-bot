require 'rails_helper'

RSpec.describe Text do
  describe '.join_lines' do
    it 'rejoins a word split by a soft hyphen' do
      expect(described_class.join_lines(["Su respuesta fue sim­", 'ple, me dijo'])).to eq('Su respuesta fue simple, me dijo')
    end

    it 'rejoins a word whose hyphen was spaced out by justification' do
      expect(described_class.join_lines(['que siga única -', 'mente sus conclusiones'])).to eq('que siga únicamente sus conclusiones')
    end

    it 'keeps a dash before a capitalised continuation' do
      expect(described_class.join_lines(['a solução -', 'Uma nova era'])).to eq('a solução - Uma nova era')
    end

    it 'keeps a page range whose hyphen ends the line' do
      expect(described_class.join_lines(['Appl Environ Microbiol 60 (7): 2650-', '2656. PMC 201698.']))
        .to eq('Appl Environ Microbiol 60 (7): 2650-2656. PMC 201698.')
    end
  end
end
