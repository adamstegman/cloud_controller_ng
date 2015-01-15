module VCAP::CloudController
  class PackageUploadMessage
    attr_reader :package_path, :package_guid

    def initialize(package_guid, opts)
      @package_guid = package_guid
      @package_path = opts['bits_path']
    end

    def validate
      return false, 'An application zip file must be uploaded.' unless @package_path
      true
    end
  end

  class PackageStagingMessage
    attr_reader :droplet_guid, :package_guid
    attr_accessor :error

    def self.create_from_http_request(package_guid, droplet_guid, body)
      opts = body && MultiJson.load(body)
      opts = {} unless opts.is_a?(Hash)
      PackageStagingMessage.new(package_guid, droplet_guid, opts)
    rescue MultiJson::ParseError => e
      message = PackageStagingMessage.new(package_guid, droplet_guid, {})
      message.error = e.message
      message
    end

    def initialize(package_guid, droplet_guid, opts)
      @package_guid = package_guid
      @droplet_guid = droplet_guid
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

  class PackageCreateMessage
    attr_reader :space_guid, :type, :url
    attr_accessor :error
    def self.create_from_http_request(space_guid, body)
      opts = body && MultiJson.load(body)
      raise MultiJson::ParseError.new('invalid request body') unless opts.is_a?(Hash)
      PackageCreateMessage.new(space_guid, opts)
    rescue MultiJson::ParseError => e
      message = PackageCreateMessage.new(space_guid, {})
      message.error = e.message
      message
    end

    def initialize(space_guid, opts)
      @space_guid = space_guid
      @type     = opts['type']
      @url      = opts['url']
    end

    def validate
      return false, [error] if error
      errors = []
      errors << validate_type_field
      errors << validate_url
      errs = errors.compact
      [errs.length == 0, errs]
    end

    private

    def validate_type_field
      return 'The type field is required' if @type.nil?
      valid_type_fields = %w(bits docker)

      if !valid_type_fields.include?(@type)
        return "The type field needs to be one of '#{valid_type_fields.join(', ')}'"
      end
      nil
    end

    def validate_url
      return 'The url field cannot be provided when type is bits.' if @type == 'bits' && !@url.nil?
      return 'The url field must be provided for type docker.' if @type == 'docker' && @url.nil?
      nil
    end
  end

  class PackagesHandler
    class Unauthorized < StandardError; end
    class InvalidPackageType < StandardError; end
    class InvalidPackage < StandardError; end
    class SpaceNotFound < StandardError; end
    class PackageNotFound < StandardError; end
    class BitsAlreadyUploaded < StandardError; end

    def initialize(config, stagers)
      @config = config
      @stagers = stagers
    end

    def create(message, access_context)
      package          = PackageModel.new
      package.space_guid = message.space_guid
      package.type     = message.type
      package.url      = message.url
      package.state = message.type == 'bits' ? PackageModel::CREATED_STATE : PackageModel::READY_STATE

      space = Space.find(guid: package.space_guid)
      raise SpaceNotFound if space.nil?

      raise Unauthorized if access_context.cannot?(:create, package, space)
      package.save

      package
    rescue Sequel::ValidationFailed => e
      raise InvalidPackage.new(e.message)
    end

    def upload(message, access_context)
      package = PackageModel.find(guid: message.package_guid)

      raise PackageNotFound if package.nil?
      raise InvalidPackageType.new('Package type must be bits.') if package.type != 'bits'
      raise BitsAlreadyUploaded.new('Bits may be uploaded only once. Create a new package to upload different bits.') if package.state != PackageModel::CREATED_STATE

      space = Space.find(guid: package.space_guid)
      raise SpaceNotFound if space.nil?

      raise Unauthorized if access_context.cannot?(:create, package, space)

      package.update(state: PackageModel::PENDING_STATE)

      bits_upload_job = Jobs::Runtime::PackageBits.new(package.guid, message.package_path)
      Jobs::Enqueuer.new(bits_upload_job, queue: Jobs::LocalQueue.new(@config)).enqueue

      package
    end

    def delete(guid, access_context)
      package = PackageModel.find(guid: guid)
      return nil if package.nil?

      space = Space.find(guid: package.space_guid)

      package.db.transaction do
        package.lock!
        raise Unauthorized if access_context.cannot?(:delete, package, space)
        package.destroy
      end

      blobstore_delete = Jobs::Runtime::BlobstoreDelete.new(package.guid, :package_blobstore, nil)
      Jobs::Enqueuer.new(blobstore_delete, queue: 'cc-generic').enqueue

      package
    end

    def show(guid, access_context)
      package = PackageModel.find(guid: guid)
      return nil if package.nil?
      raise Unauthorized if access_context.cannot?(:read, package)
      package
    end

    def stage(message, access_context)
      package = PackageModel.find(guid: message.package_guid)
      # return nil if package.nil?
      # raise Unauthorized if access_context.cannot?(:read, package)
      droplet = DropletModel.find(guid: message.droplet_guid)
      # return nil if droplet.nil?
      # raise Unauthorized if access_context.cannot?(:read, droplet)

      @stagers.stager_for_package(package).stage_package(droplet, message.stack, message.memory_limit, message.disk_limit)
    end
  end
end
