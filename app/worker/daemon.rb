class Worker
  class Daemon
    def initialize(service_uri = nil)
      @service_uri = service_uri || ENV['BOT_HTTP'] || ENV['BOT_DRB']
      @shutdown_reason = nil
    end

    def run
      trap(:TERM) { @shutdown_reason = :restart }
      trap(:INT) { @shutdown_reason = :cancel }

      if @service_uri.start_with?('http')
        run_http
      else
        run_drb
      end
    end

    private

    def run_http
      http_client = Bot::Worker::HTTPClient.new(@service_uri, timeout: 0.1)
      puts "Worker connected to HTTP service at #{@service_uri}"

      loop do
        break if @shutdown_reason

        begin
          result   = http_client.get('queue/dequeue')
          job_data = result['job']

          if job_data
            job = {job_data: job_data, worker_uri: result['service_uri'] || @service_uri}
            if @shutdown_reason
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
          next if @shutdown_reason
          puts "Error dequeuing: #{e.message}"
          sleep 1
        end
      end
    end

    def run_drb
      manager = DRbObject.new_with_uri(@service_uri)
      puts "Worker connected to DRb service at #{@service_uri}"

      loop do
        break if @shutdown_reason && manager.queue_size == 0

        begin
          job_data = manager.dequeue(timeout: 1)
        rescue => e
          next if @shutdown_reason
          puts "Error dequeuing: #{e.message}"
          sleep 1
          next
        end

        next unless job_data

        job = {job_data: job_data, worker_uri: manager.bot_service_uri}
        if @shutdown_reason
          pid = fork { process_message(job) }
          Process.detach(pid)
          exit(0)
        else
          process_message(job)
        end
      end
    end

    def process_message(job)
      job_data   = SymMash.new(job[:job_data])
      worker_uri = job[:worker_uri]
      job_id     = job_data.id
      control     = Bot::Worker::Client.new(worker_uri) if worker_uri
      control   ||= Worker.service
      runner      = Bot::JobRunner.new(
        cancelled: ->(id) { control.job_cancelled?(id) },
        interrupted: ->(_id) { @shutdown_reason },
        finished:  ->(id) { control.finish_job(id) },
      )
      runner.run(job_id) do
        Sequel::Model.db.disconnect
        service = Bot::Worker::Client.new(worker_uri) if worker_uri
        worker  = Worker.new(SymMash.new(job_data.message), service: service || Worker.service, job_id: job_id)
        worker.process
      end
    rescue => e
      STDERR.puts "Error processing message: #{e.class}: #{e.message}"
      STDERR.puts e.backtrace.join("\n")
    end
  end
end
