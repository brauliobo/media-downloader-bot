require_relative 'boot'

require_relative 'bot/worker/client'
require_relative 'worker'

class WorkerDaemon
  def initialize(service_uri = nil)
    @service_uri = service_uri || ENV['BOT_HTTP'] || ENV['BOT_DRB']
    @shutdown = false
  end

  def run
    trap(:TERM) { @shutdown = true }
    trap(:INT) { @shutdown = true }

    if @service_uri.start_with?('http')
      run_http
    else
      run_drb
    end
  end

  private

  def run_http
    http_client = Faraday.new(url: @service_uri) do |conn|
      conn.options.timeout = 0.1
    end
    puts "Worker connected to HTTP service at #{@service_uri}"

    loop do
      break if @shutdown

      begin
        response = http_client.get('/queue/dequeue')
        result = response.body.is_a?(String) ? JSON.parse(response.body) : response.body
        job_data = result['job']
        
        if job_data
          job = {message_data: job_data, worker_uri: result['service_uri'] || @service_uri}
          if @shutdown
            pid = fork { process_message(job) }
            Process.detach(pid)
            exit(0)
          else
            process_message(job)
          end
        end
      rescue Faraday::TimeoutError, Faraday::ConnectionFailed
        sleep 0.1
      rescue => e
        next if @shutdown
        puts "Error dequeuing: #{e.message}"
        sleep 1
      end
    end
  end

  def run_drb
    manager = DRbObject.new_with_uri(@service_uri)
    puts "Worker connected to DRb service at #{@service_uri}"

    loop do
      break if @shutdown && manager.queue_size == 0

      begin
        job_data = manager.dequeue(timeout: 1)
      rescue => e
        next if @shutdown
        puts "Error dequeuing: #{e.message}"
        sleep 1
        next
      end

      next unless job_data

      job = {message_data: job_data, worker_uri: manager.bot_service_uri}
      if @shutdown
        pid = fork { process_message(job) }
        Process.detach(pid)
        exit(0)
      else
        process_message(job)
      end
    end
  end

  def process_message(job)
    message_data = job[:message_data]
    worker_uri = job[:worker_uri]

    msg = SymMash.new(message_data)
    Worker.service = Bot::Worker::Client.new worker_uri if worker_uri
    worker = Worker.new msg

    worker.process
  rescue => e
    STDERR.puts "Error processing message: #{e.class}: #{e.message}"
    STDERR.puts e.backtrace.join("\n")
  end
end

