module Utils
  # What the oxiroute proxy publishes (Prometheus text) about its upstream pools.
  class Oxiroute
    TIMEOUT = 5

    def initialize(url: ENV.fetch('OXIROUTE_METRICS', 'http://127.0.0.1:9900/metrics')) = @url = URI(url)

    # How many requests wait for a free server of the pool.
    def queue_depth(pool) = metric('oxiroute_pool_queue_depth', pool).to_i

    private

    def metric(name, pool)
      prefix = %(#{name}{pool="#{pool}"} )
      line   = body.lines.find { |text| text.start_with?(prefix) } or raise "oxiroute has no #{name} for the pool #{pool}"
      line.split.last
    end

    def body = Net::HTTP.start(@url.host, @url.port, open_timeout: TIMEOUT, read_timeout: TIMEOUT) { |http| http.get(@url.request_uri).tap(&:value).body }
  end
end
