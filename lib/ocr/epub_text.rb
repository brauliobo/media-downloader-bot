class Ocr
  module EPUBText
    require 'nokogiri'

    # Extract text from an EPUB and save it in the same JSON structure as PDFs
    def self.transcribe(epub_path, json_path, stl: nil, opts: nil, **_kwargs)
      Dir.mktmpdir do |dir|
        Sh.run "unzip -qq -o #{Sh.escape epub_path} -d #{dir}"

        opf_path = find_opf_path(dir)
        raise 'EPUB OPF not found' unless opf_path

        base_dir = File.dirname(opf_path)
        manifest, spine = parse_opf(opf_path)

        transcription = { metadata: { pages: [] }, content: { paragraphs: [] } }

        spine.each_with_index do |item_id, idx|
          href = manifest[item_id]
          next unless href
          page_num = idx + 1
          stl&.update "Extracting chapter #{page_num}/#{spine.size}"

          path = File.expand_path(href, base_dir)
          next unless File.exist?(path)
          doc = Nokogiri::HTML(File.read(path))

          elements = doc.css('body h1, body h2, body h3, body h4, body h5, body h6, body p, body li')
          elements.each do |el|
            text = el.text.to_s.encode('UTF-8', invalid: :replace, undef: :replace, replace: '').gsub(/\s+/, ' ').strip
            next if text.empty?
            kind = el.name =~ /h\d/ ? 'heading' : 'text'
            transcription[:content][:paragraphs] << { text: text, page_numbers: [page_num], merged: false, kind: kind }
          end

          transcription[:metadata][:pages] << { page_number: page_num, href: href }
        end

        stl&.update 'Merging paragraphs'
        blocks = Ocr.util.merge_paragraphs(transcription[:content][:paragraphs])
        transcription[:content][:paragraphs] = blocks

        stl&.update 'Detecting language'
        if defined?(Ocr::Ollama) && Ocr::Ollama.respond_to?(:detect_language)
          transcription[:metadata][:language] = Ocr::Ollama.detect_language(blocks)
        end

        stl&.update 'Saving transcription'
        File.write json_path, JSON.pretty_generate(transcription)
        stl&.update 'Done'
      end
    end

    def self.find_opf_path(root)
      container = File.join(root, 'META-INF/container.xml')
      return nil unless File.exist?(container)
      doc = Nokogiri::XML(File.read(container))
      doc.remove_namespaces!
      path = doc.at_css('rootfile')&.[]('full-path')
      path ? File.join(root, path) : nil
    end

    def self.parse_opf(opf_path)
      doc = Nokogiri::XML(File.read(opf_path))
      doc.remove_namespaces!
      manifest = {}
      doc.css('manifest item').each { |it| manifest[it['id']] = it['href'] }
      spine = doc.css('spine itemref').map { |ir| ir['idref'] }.compact
      [manifest, spine]
    end
  end
end







