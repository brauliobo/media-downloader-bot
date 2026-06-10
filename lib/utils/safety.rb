require 'ipaddr'
require 'resolv'
require 'tmpdir'
require 'uri'

module Utils
  module Safety
    SUBTITLE_EXTS = %w[ass srt ssa sbv srv1 srv2 srv3 json3 ttml vtt].freeze
    FILTER_RE     = /\A[0-9A-Za-z_=:.+,\-]+\z/.freeze
    TIME_RE       = /\A(?:(?:\d{1,2}:)?\d{1,2}:)?\d{1,2}(?:\.\d{1,3})?\z/.freeze
    TESS_LANG_RE  = /\A[a-z]{2,3}(?:\+[a-z]{2,3})*\z/.freeze

    PRIVATE_NETS = %w[
      0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16
      172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.168.0.0/16 198.18.0.0/15
      198.51.100.0/24 203.0.113.0/24 224.0.0.0/4 240.0.0.0/4
      ::/128 ::1/128 fc00::/7 fe80::/10 ff00::/8
    ].map { |cidr| IPAddr.new(cidr) }.freeze

    module_function

    def basename(name, fallback: 'file')
      base = File.basename(name.to_s.delete("\0"))
      base = fallback if base.empty? || base == '.' || base == '..'
      base
    end

    def contained_path(dir, name, fallback: 'file')
      root = File.expand_path(dir || Dir.tmpdir)
      file = File.expand_path(basename(name, fallback: fallback), root)
      raise ArgumentError, "path escapes #{root}" unless inside?(file, root)
      file
    end

    def inside?(path, root)
      path = File.expand_path(path)
      root = File.expand_path(root)
      path == root || path.start_with?("#{root}#{File::SEPARATOR}")
    end

    def inside_any?(path, roots)
      roots.compact.any? { |root| inside?(path, root) }
    end

    def real_file_inside?(path, root)
      expanded = File.realpath(path)
      base     = File.realpath(root)
      File.file?(expanded) && inside?(expanded, base)
    rescue Errno::ENOENT, Errno::EACCES
      false
    end

    def safe_filter(value)
      value = value.to_s
      raise ArgumentError, "unsafe video filter: #{value.inspect}" unless value.match?(FILTER_RE)
      value
    end

    def safe_time?(value)
      value.to_s.match?(TIME_RE)
    end

    def subtitle_ext(value)
      ext = value.to_s.downcase.delete_prefix('.')
      raise ArgumentError, "unsupported subtitle extension: #{value}" unless SUBTITLE_EXTS.include?(ext)
      ext
    end

    def concat_manifest_path(path)
      value = path.to_s
      raise ArgumentError, 'unsafe concat path' if value.match?(/[\r\n]/)
      "file '#{value.gsub("'", "'\\\\''")}'"
    end

    def netscape_field(value)
      value.to_s.gsub(/[\t\r\n]/, ' ').strip
    end

    def hostname?(value)
      value.to_s.match?(/\A\.?[A-Za-z0-9.-]+\z/)
    end

    def public_http_url?(value)
      uri = URI.parse(value.to_s)
      return false unless uri.is_a?(URI::HTTP) && uri.host
      return false if uri.userinfo || uri.host == 'localhost'

      addresses = Resolv.getaddresses(uri.host)
      addresses.any? && addresses.all? { |addr| public_ip?(addr) }
    rescue URI::InvalidURIError, Resolv::ResolvError
      false
    end

    def public_ip?(value)
      ip = IPAddr.new(value)
      PRIVATE_NETS.none? { |net| net.include?(ip) }
    rescue IPAddr::InvalidAddressError
      false
    end

    def tesseract_lang(value, fallback:)
      lang = value.to_s.downcase
      lang.match?(TESS_LANG_RE) ? lang : fallback
    end
  end
end
