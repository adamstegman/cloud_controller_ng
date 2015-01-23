require 'spec_helper'
require 'handlers/droplets_handler'

module VCAP::CloudController
  describe StagingMessage do
    let(:package_guid) { 'package-guid' }
    let(:memory_limit) { 1024 }

    describe 'create_from_http_request' do
      context 'when the body is valid json' do
        let(:body) { MultiJson.dump({ memory_limit: memory_limit }) }

        it 'creates a StagingMessage from the json' do
          staging_message = StagingMessage.create_from_http_request(package_guid, body)
          valid, errors   = staging_message.validate

          expect(valid).to be_truthy
          expect(errors).to be_empty
        end
      end

      context 'when the body is not valid json' do
        let(:body) { '{{' }

        it 'returns a StagingMessage that is not valid' do
          staging_message = StagingMessage.create_from_http_request(package_guid, body)
          valid, errors   = staging_message.validate

          expect(valid).to be_falsey
          expect(errors[0]).to include('parse error')
        end
      end
    end

    context 'when only required fields are provided' do
      let(:body) { '{}' }

      it 'is valid' do
        psm           = StagingMessage.create_from_http_request(package_guid, body)
        valid, errors = psm.validate
        expect(valid).to be_truthy
        expect(errors).to be_empty
      end

      it 'provides default values' do
        psm = StagingMessage.create_from_http_request(package_guid, body)

        expect(psm.memory_limit).to eq(1024)
        expect(psm.disk_limit).to eq(4096)
        expect(psm.stack).to eq(Stack.default.name)
      end
    end

    context 'when memory_limit is not an integer' do
      let(:body) { MultiJson.dump({ memory_limit: 'stringsarefun' }) }

      it 'is not valid' do
        psm           = StagingMessage.create_from_http_request(package_guid, body)
        valid, errors = psm.validate
        expect(valid).to be_falsey
        expect(errors[0]).to include('must be an Integer')
      end
    end

    context 'when disk_limit is not an integer' do
      let(:body) { MultiJson.dump({ disk_limit: 'stringsarefun' }) }

      it 'is not valid' do
        psm           = StagingMessage.create_from_http_request(package_guid, body)
        valid, errors = psm.validate
        expect(valid).to be_falsey
        expect(errors[0]).to include('must be an Integer')
      end
    end

    context 'when stack is not a string' do
      let(:body) { MultiJson.dump({ stack: 1024 }) }

      it 'is not valid' do
        psm           = StagingMessage.create_from_http_request(package_guid, body)
        valid, errors = psm.validate
        expect(valid).to be_falsey
        expect(errors[0]).to include('must be a String')
      end
    end
  end

  describe DropletsHandler do
    let(:config) { TestConfig.config }
    let(:stagers) { double(:stagers) }
    let(:droplets_handler) { described_class.new(config, stagers) }
    let(:access_context) { double(:access_context) }

    before do
      allow(access_context).to receive(:cannot?).and_return(false)
    end

    describe '#create' do
      let(:space) { Space.make }
      let(:package) { PackageModel.make(space_guid: space.guid) }
      let(:package_guid) { package.guid }
      let(:stack) { 'trusty32' }
      let(:memory_limit) { 12340 }
      let(:disk_limit) { 32100 }
      let(:body) { { stack: stack, memory_limit: memory_limit, disk_limit: disk_limit }.stringify_keys }
      let(:staging_message) { StagingMessage.new(package_guid, body) }
      let(:stager) { double(:stager) }

      context 'when the package does exist' do
        context 'and the user is a space developer' do
          before do
            allow(stagers).to receive(:stager_for_package).with(package).and_return(stager)
            allow(stager).to receive(:stage_package)
          end

          it 'creates a droplet' do
            droplet = nil
            expect {
              droplet = droplets_handler.create(staging_message, access_context)
            }.to change(DropletModel, :count).by(1)
            expect(droplet.state).to eq(DropletModel::PENDING_STATE)
          end

          it 'initiates a staging request' do
            droplets_handler.create(staging_message, access_context)
            droplet = DropletModel.last
            expect(stager).to have_received(:stage_package).with(droplet, stack, memory_limit, disk_limit)
          end
        end

        context 'and the user is not a space developer' do
          before do
            allow(access_context).to receive(:cannot?).and_return(true)
          end

          it 'fails with Unauthorized' do
            expect {
              droplets_handler.create(staging_message, access_context)
            }.to raise_error(DropletsHandler::Unauthorized)
            expect(access_context).to have_received(:cannot?).with(:create, kind_of(DropletModel), space)
          end
        end
      end

      context 'when the package does not exist' do
        let(:package_guid) { 'non-existant' }

        it 'fails with PackageNotFound' do
          expect {
            droplets_handler.create(staging_message, access_context)
          }.to raise_error(DropletsHandler::PackageNotFound)
        end
      end
    end
  end
end
