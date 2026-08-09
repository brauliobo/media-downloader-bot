require_relative '../utils/sh'
require_relative '../utils/thumb'

module Audiobook
  class Cover
    MIN_AREA_COVERAGE = 0.5
    MIN_AXIS_COVERAGE = 0.5

    attr_reader :source_path, :page_number, :image_width, :image_height, :area_coverage, :page_width, :page_height

    def self.detect(pdf_path, page:)
      output, stderr, status = Sh.run [
        'pdfimages', '-f', page.number.to_s, '-l', page.number.to_s, '-list', pdf_path
      ]
      Sh.assert_success!('PDF cover inspection failed', stderr, status: status)

      images = output.lines.filter_map { |line| image_metrics(line, page) }
      image = images.max_by { |candidate| candidate.area_coverage }
      return unless image&.large?

      new(
        source_path:   pdf_path,
        page_number:   page.number,
        image_width:   image.width,
        image_height: image.height,
        area_coverage: image.area_coverage,
        page_width:    page.width,
        page_height:   page.height,
      )
    end

    def initialize(source_path:, page_number:, image_width:, image_height:, area_coverage:, page_width:, page_height:)
      @source_path   = source_path
      @page_number   = page_number
      @image_width   = image_width
      @image_height  = image_height
      @area_coverage = area_coverage
      @page_width    = page_width
      @page_height   = page_height
    end

    def thumbnail(dir:, base:)
      output_base = File.join(dir, "#{base}-cover")
      source_image = "#{output_base}.jpg"
      _stdout, stderr, status = Sh.run [
        'pdftoppm', '-f', page_number.to_s, '-l', page_number.to_s,
        '-jpeg', '-singlefile', source_path, output_base
      ]
      Sh.assert_success!('PDF cover rendering failed', stderr, status: status, output: source_image)

      info = SymMash.new(thumbnail: source_image, width: page_width, height: page_height)
      Utils::Thumb.process(info, base_filename: output_base, local: true)
    end

    ImageMetrics = Data.define(:width, :height, :display_width, :display_height, :page_width, :page_height) do
      def area_coverage
        display_width * display_height / (page_width * page_height)
      end

      def large?
        area_coverage >= Cover::MIN_AREA_COVERAGE &&
          display_width / page_width >= Cover::MIN_AXIS_COVERAGE &&
          display_height / page_height >= Cover::MIN_AXIS_COVERAGE
      end
    end

    def self.image_metrics(line, page)
      fields = line.split
      return unless fields.size >= 14 && fields[0].match?(/\A\d+\z/) && fields[2] == 'image'

      width  = fields[3].to_i
      height = fields[4].to_i
      x_ppi  = fields[12].to_f
      y_ppi  = fields[13].to_f
      return unless width.positive? && height.positive? && x_ppi.positive? && y_ppi.positive?

      ImageMetrics.new(
        width:          width,
        height:         height,
        display_width:  width.fdiv(x_ppi) * 72,
        display_height: height.fdiv(y_ppi) * 72,
        page_width:     page.width.to_f,
        page_height:    page.height.to_f,
      )
    end
    private_class_method :image_metrics
  end
end
