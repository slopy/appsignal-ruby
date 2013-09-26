module Appsignal
  class Agent
    ACTION = 'log_entries'.freeze

    attr_reader :aggregator, :thread, :active, :sleep_time, :transmitter, :aggregator_semaphore

    def initialize
      return unless Appsignal.active?
      @sleep_time = 60.0
      @aggregator = Aggregator.new
      @aggregator_semaphore = Mutex.new
      @retry_request = true
      @thread = Thread.new do
        while true do
          send_queue if aggregator.has_transactions?
          Appsignal.logger.debug("Sleeping #{sleep_time}")
          sleep(sleep_time)
        end
      end
      @transmitter = Transmitter.new(
        Appsignal.config.fetch(:endpoint),
        ACTION,
        Appsignal.config.fetch(:api_key)
      )
      Appsignal.logger.info("Started Appsignal agent version #{Appsignal::VERSION}")
    end

    def enqueue(transaction)
      aggregator_semaphore.synchronize do
        aggregator.add(transaction)
      end
    end

    def send_queue
      Appsignal.logger.debug("Sending queue")
      aggregator_to_be_sent = nil
      aggregator_semaphore.synchronize do
        aggregator_to_be_sent = aggregator
        @aggregator = Aggregator.new
      end
      begin
        handle_result(
          transmitter.transmit(aggregator_to_be_sent.post_processed_queue!)
        )
      rescue Exception => ex
        Appsignal.logger.error "#{ex.class} while sending queue: #{ex.message}"
        Appsignal.logger.error ex.backtrace.join('\n')
      end
    end

    def forked!
      @forked = true
      @aggregator = Aggregator.new
      Appsignal.logger.info("Forked the Appsignal agent")
    end

    def forked?
      @forked ||= false
    end

    def shutdown(send_current_queue=false)
      Appsignal.logger.info("Shutting down the agent")
      ActiveSupport::Notifications.unsubscribe(Appsignal.subscriber)
      Thread.kill(thread) if thread
      send_queue if send_current_queue && @aggregator.has_transactions?
    end

    protected

    def handle_result(code)
      Appsignal.logger.debug "Queue sent, response code: #{code}"
      case code.to_i
      when 200 # ok
      when 420 # Enhance Your Calm
        @sleep_time = sleep_time * 1.5
      when 413 # Request Entity Too Large
        @sleep_time = sleep_time / 1.5
      when 429
        Appsignal.logger.error "Too many requests sent"
        shutdown
      when 406
        Appsignal.logger.error "Your appsignal gem cannot "\
          "communicate with the API anymore, please upgrade."
        shutdown
      when 402
        Appsignal.logger.error "Payment required"
        shutdown
      when 401
        Appsignal.logger.error "API token cannot be authorized"
        shutdown
      else
        Appsignal.logger.error "Unknown Appsignal response code: "\
          "'#{code}'"
      end
    end
  end
end
