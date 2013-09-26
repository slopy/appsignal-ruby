require 'erb'
require 'yaml'
require 'appsignal/careful_logger'
require 'erb'

module Appsignal
  class Config
    include Appsignal::CarefulLogger

    DEFAULT_CONFIG = {
      :ignore_exceptions => [],
      :endpoint => 'https://push.appsignal.com/1',
      :slow_request_threshold => 200
    }.freeze

    attr_reader :configurations, :project_path, :env

    def initialize(project_path, env, logger=Appsignal.logger)
      @project_path = project_path || ENV['PWD']
      @env = env.to_sym
      @logger = logger
      @configurations = {}
    end

    def load
      return unless load_configurations
      return unless current_environment_present
      warn_if_duplicate_api_keys

      if Appsignal.respond_to?(:logger) && @logger == Appsignal.logger
        @logger.level = Logger::DEBUG if configurations[env][:debug]
      end
      DEFAULT_CONFIG.merge(configurations[env])
    end

    def load_all
      return unless load_configurations
      warn_if_duplicate_api_keys

      {}.tap do |result|
        configurations.each do |env, config|
          result[env] = DEFAULT_CONFIG.merge(config)
        end
      end
    end

    protected

    def config_file
      File.join(project_path, 'config', 'appsignal.yml')
    end

    def load_configurations
      unless load_configurations_from_disk || load_configurations_from_env
        carefully_log_error "no config file found at '#{config_file}'
          and no APPSIGNAL_API_KEY found in ENV"
        return false
      end
      true
    end

    def load_configurations_from_disk
      file = config_file
      unless File.exists?(file)
        return false
      end
      @configurations = YAML.load(ERB.new(IO.read(file)).result)
      configurations.each { |k,v| v.symbolize_keys! }
      configurations.symbolize_keys!
      true
    end

    def load_configurations_from_env
      api_key = ENV['APPSIGNAL_API_KEY']
      env = ENV['RAILS_ENV'] || :production
      if api_key.present?
        @configurations = {env.to_sym => {:api_key => api_key, :active => true}}
        true
      else
        false
      end
    end

    def warn_if_duplicate_api_keys
      keys = configurations.each_value.map { |config| config[:api_key] }.compact
      if keys.uniq.count < keys.count
        carefully_log_error('Warning: Duplicate API keys found in appsignal.yml')
      end
    end

    def current_environment_present
      return true if configurations[env].present?
      carefully_log_error "config for '#{env}' not found"
      false
    end
  end
end
