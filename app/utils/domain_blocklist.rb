module Utils
  # Blocklist Project porn domains, downloaded once into tmp/cache; a host is blocked when it or a parent domain is listed.
  class DomainBlocklist
    URL  = 'https://blocklistproject.github.io/Lists/alt-version/porn-nl.txt'.freeze
    PATH = Rails.root.join('tmp/cache/blocklist/porn.txt').to_s.freeze

    def self.domains = @domains ||= File.foreach(path, chomp: true).lazy.reject { _1.empty? || _1.start_with?('#') }.to_set

    def self.path = File.exist?(PATH) ? PATH : HTTP.download_public(URL, PATH, max_bytes: 64.megabytes) && PATH

    def self.blocked?(host)
      labels = host.split('.')
      labels.each_index.any? { |i| domains.include?(labels[i..].join('.')) }
    end
  end
end
