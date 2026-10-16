require 'rails_helper'

RSpec.describe TDBot::CaptionEdit do
  Entity = Struct.new(:offset, :length, :type) do
    def to_h = { offset: offset, length: length, type: type }
  end
  Caption = Struct.new(:text, :entities)

  let(:caption) { Caption.new("📚 Livro\n\n#Velho #Tag", [Entity.new(3, 5, 'bold'), Entity.new(10, 6, 'hashtag'), Entity.new(17, 4, 'hashtag')]) }

  it 'swaps the text, keeping the formatting before it and counting in UTF-16 units' do
    edited = described_class.replace(caption, '#Velho #Tag', '#Novo')

    expect(edited).to include('text' => "📚 Livro\n\n#Novo")
    expect(edited['entities']).to eq([{ offset: 3, length: 5, type: 'bold' }])
  end

  it 'moves the formatting after the replaced text' do
    edited = described_class.replace(caption, '#Velho', '#Muito #Novo')

    expect(edited['text']).to eq("📚 Livro\n\n#Muito #Novo #Tag")
    expect(edited['entities']).to eq([{ offset: 3, length: 5, type: 'bold' }, { offset: 23, length: 4, type: 'hashtag' }])
  end

  it 'appends to a caption that had nothing to swap' do
    expect(described_class.replace(caption, '', '#Novo')['text']).to eq("📚 Livro\n\n#Velho #Tag\n\n#Novo")
  end

  it 'refuses a caption that does not carry the old text' do
    expect { described_class.replace(caption, '#Other', '#Novo') }.to raise_error(ArgumentError, /not in the caption/)
  end
end
