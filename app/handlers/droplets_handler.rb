module VCAP::CloudController
  class StagingMessage
    attr_reader :package_guid
    attr_accessor :error

    def self.create_from_http_request(package_guid, body)
      opts = body && MultiJson.load(body)
      opts = {} unless opts.is_a?(Hash)
      StagingMessage.new(package_guid, opts)
    rescue MultiJson::ParseError => e
      message = StagingMessage.new(package_guid, {})
      message.error = e.message
      message
    end

    def initialize(package_guid, opts)
      @package_guid = package_guid
      @memory_limit = opts['memory_limit']
      @disk_limit = opts['disk_limit']
      @stack = opts['stack']

      @config = Config.config
    end

    def validate
      return false, [error] if error
      errors = []
      errors << validate_memory_limit_field
      errors << validate_disk_limit_field
      errors << validate_stack_field
      errs = errors.compact
      [errs.length == 0, errs]
    end

    def stack
      @stack ||= Stack.default.name
    end

    def memory_limit
      [@memory_limit, default_memory_limit].compact.max
    end

    def disk_limit
      [@disk_limit, default_disk_limit].compact.max
    end

    private

    def default_disk_limit
      @config[:staging][:minimum_staging_disk_mb] || 4096
    end

    def default_memory_limit
      (@config[:staging] && @config[:staging][:minimum_staging_memory_mb] || 1024)
    end

    def validate_memory_limit_field
      return 'The memory_limit field must be an Integer' unless @memory_limit.is_a?(Integer) || @memory_limit.nil?
      nil
    end

    def validate_disk_limit_field
      return 'The disk_limit field must be an Integer' unless @disk_limit.is_a?(Integer) || @disk_limit.nil?
      nil
    end

    def validate_stack_field
      return 'The stack field must be a String' unless @stack.is_a?(String) || @stack.nil?
      nil
    end
  end

  class DropletsHandler
    class Unauthorized < StandardError; end

    def initialize(config, stagers)
      @config = config
      @stagers = stagers
    end

    def create(message, access_context)
      package = PackageModel.find(guid: message.package_guid)
      # return nil if package.nil?
      # raise Unauthorized if access_context.cannot?(:read, package)
      droplet = DropletModel.create(state: DropletModel::PENDING_STATE)
      # return nil if droplet.nil?
      # raise Unauthorized if access_context.cannot?(:read, droplet)

      @stagers.stager_for_package(package).stage_package(droplet, message.stack, message.memory_limit, message.disk_limit)
      droplet
    end
  end
end
