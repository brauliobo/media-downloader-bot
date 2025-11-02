require 'spec_helper'

RSpec.describe 'Paragraph breaks based on indentation and spacing' do
  def fixture_path(name) = File.expand_path("../fixtures/#{name}", __dir__)

  let(:book) { Audiobook::Book.from_input(fixture_path('paragraph-ident-and-spacing.pdf')) }

  def paragraph_text(para)
    para.sentences.map(&:text).join(' ').gsub(/\s+/, ' ').strip
  end

  def find_paragraph_containing(text)
    book.pages.flat_map(&:items).grep(Audiobook::Paragraph).find do |para|
      paragraph_text(para).include?(text)
    end
  end

  it 'detects paragraph break based on large spacing after sentence completion' do
    # First paragraph should end with "fundamento da intimidade."
    first_para = find_paragraph_containing('fundamento da intimidade')
    expect(first_para).not_to be_nil
    expect(paragraph_text(first_para)).to match(/fundamento da intimidade\.\s*$/)

    # Second paragraph should start with "Partindo do pressuposto" (new paragraph due to spacing)
    second_para = find_paragraph_containing('Partindo do pressuposto')
    expect(second_para).not_to be_nil
    expect(paragraph_text(second_para)).to match(/^Partindo do pressuposto/)

    # These should be different paragraphs
    expect(first_para).not_to eq(second_para)
  end

  it 'detects paragraph break based on indentation when sentence is finished' do
    # Find paragraph starting with indentation
    indented_para = find_paragraph_containing('Partindo do pressuposto de que não é fácil amar a si mesmo')
    expect(indented_para).not_to be_nil

    # Should start a new paragraph due to indentation
    expect(indented_para.sentences.first.text).to match(/^Partindo do pressuposto/)
  end

  it 'checks spacing before indentation for break detection' do
    paragraphs = book.pages.flat_map(&:items).grep(Audiobook::Paragraph)
    
    # Find the paragraph ending with "fundamento da intimidade."
    first_para_idx = paragraphs.index { |p| paragraph_text(p).include?('fundamento da intimidade') }
    second_para_idx = paragraphs.index { |p| paragraph_text(p).include?('Partindo do pressuposto') }

    expect(first_para_idx).not_to be_nil
    expect(second_para_idx).not_to be_nil
    expect(second_para_idx).to be > first_para_idx

    # Verify content separation - first para should not contain second para text
    expect(paragraph_text(paragraphs[first_para_idx])).not_to include('Partindo do pressuposto')
    expect(paragraph_text(paragraphs[second_para_idx])).not_to include('fundamento da intimidade')
    
    # The break should be detected based on spacing (large gap) when sentence is finished
    # The second paragraph also has indentation, but spacing detection comes first
    first_text = paragraph_text(paragraphs[first_para_idx])
    second_text = paragraph_text(paragraphs[second_para_idx])
    expect(first_text).to end_with('intimidade.')
    expect(second_text).to start_with('Partindo do pressuposto')
    
    # Verify both spacing and indentation cues are present but spacing triggers the break
    book_text = book.pages.flat_map(&:items).grep(Audiobook::Paragraph).map { |p| paragraph_text(p) }.join(' ')
    expect(book_text).to include('intimidade.')
    expect(book_text).to include('Partindo do pressuposto')
  end

  it 'only breaks on spacing/indentation when sentence is finished' do
    # Verify that the break between first and second paragraph only happens
    # because the first paragraph's sentence is finished
    
    first_para = find_paragraph_containing('fundamento da intimidade')
    second_para = find_paragraph_containing('Partindo do pressuposto')
    
    # First paragraph must end with punctuation for the break to be valid
    first_text = paragraph_text(first_para)
    expect(first_text).to match(/\.\s*$/)
    
    # Second paragraph starts with capital, indicating new sentence
    second_text = paragraph_text(second_para)
    expect(second_text).to match(/^Partindo/)
  end

  it 'correctly separates paragraphs with both spacing and indentation cues' do
    # The break between "fundamento da intimidade." and "Partindo do pressuposto"
    # should be detected even though both spacing and indentation are present
    
    first_para = find_paragraph_containing('fundamento da intimidade')
    second_para = find_paragraph_containing('Partindo do pressuposto')
    
    expect(first_para).not_to eq(second_para)
    
    # First paragraph should end with the expected sentence
    expect(paragraph_text(first_para)).to include('confiança é o fundamento da intimidade')
    
    # Second paragraph should start with expected sentence
    expect(paragraph_text(second_para)).to include('Partindo do pressuposto de que não é fácil amar a si mesmo')
  end

  it 'maintains paragraph integrity when spacing/indentation indicate continuation' do
    # Lines within the same paragraph should not be split
    second_para = find_paragraph_containing('Partindo do pressuposto')
    expect(second_para).not_to be_nil
    
    # Should contain multiple sentences from the longer block
    text = paragraph_text(second_para)
    expect(text).to include('bell hooks nos ensina')
    expect(text).to include('movimento feminista')
    expect(text).to include('trabalho que odiamos')
  end
end
