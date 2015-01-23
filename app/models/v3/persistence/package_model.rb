module VCAP::CloudController
  class PackageModel < Sequel::Model(:packages)
    PACKAGE_STATES = [
      PENDING_STATE = 'PROCESSING_UPLOAD',
      READY_STATE   = 'READY',
      FAILED_STATE  = 'FAILED',
      CREATED_STATE = 'AWAITING_UPLOAD'
    ].map(&:freeze).freeze

    PACKAGE_TYPES = [
      BITS_TYPE   = 'bits',
      DOCKER_TYPE = 'docker'
    ].map(&:freeze).freeze

    def validate
      validates_includes PACKAGE_STATES, :state, allow_missing: true
    end

    def stage_with_diego?
      false
    end
  end
end
