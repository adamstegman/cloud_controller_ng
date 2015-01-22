require 'spec_helper'

module VCAP::CloudController
  module Dea
    describe Stager do
      let(:config) do
        instance_double(Config)
      end

      let(:message_bus) do
        instance_double(CfMessageBus::MessageBus, publish: nil)
      end

      let(:dea_pool) do
        instance_double(Dea::Pool)
      end

      let(:stager_pool) do
        instance_double(Dea::StagerPool)
      end

      let(:runners) do
        instance_double(Runners)
      end

      let(:runner) { double(:Runner) }

      subject(:stager) do
        Stager.new(app, config, message_bus, dea_pool, stager_pool, runners)
      end

      let(:stager_task) do
        double(AppStagerTask)
      end

      let(:reply_json_error) { nil }
      let(:reply_error_info) { nil }
      let(:detected_buildpack) { nil }
      let(:detected_start_command) { 'wait_for_godot' }
      let(:buildpack_key) { nil }
      let(:droplet_hash) { 'droplet-sha1' }
      let(:reply_json) do
        {
          'task_id' => 'task-id',
          'task_log' => 'task-log',
          'task_streaming_log_url' => nil,
          'detected_buildpack' => detected_buildpack,
          'buildpack_key' => buildpack_key,
          'detected_start_command' => detected_start_command,
          'error' => reply_json_error,
          'error_info' => reply_error_info,
          'droplet_sha1' => droplet_hash,
        }
      end
      let(:staging_result) { StagingResponse.new(reply_json) }

      describe '#stage' do
        let(:app) do
          AppFactory.make
        end

        before do
          allow(AppStagerTask).to receive(:new).and_return(stager_task)
          allow(stager_task).to receive(:stage).and_yield('fake-staging-result').and_return('fake-stager-response')
          allow(runners).to receive(:runner_for_app).with(app).and_return(runner)
          allow(runner).to receive(:start).with('fake-staging-result')
        end

        it 'stages the app with a stager task' do
          stager.stage_app
          expect(stager_task).to have_received(:stage)
          expect(AppStagerTask).to have_received(:new).with(config,
                                                            message_bus,
                                                            app,
                                                            dea_pool,
                                                            stager_pool,
                                                            an_instance_of(CloudController::Blobstore::UrlGenerator))
        end

        it 'starts the app with the returned staging result' do
          stager.stage_app
          expect(runner).to have_received(:start).with('fake-staging-result')
        end

        it 'records the stager response on the app' do
          stager.stage_app
          expect(app.last_stager_response).to eq('fake-stager-response')
        end
      end

      describe '#stage_package' do
        let(:stager_task) { double(PackageStagerTask) }
        let(:staging_message) { double(:staging_message) }
        let(:blobstore_url_generator) { double(:blobstore_url_generator) }

        let(:stack) { 'lucid64' }
        let(:mem) { 1024 }
        let(:disk) { 1024 }

        before do
          allow(PackageStagerTask).to receive(:new).and_return(stager_task)
          allow(PackageDEAStagingMessage).to receive(:new).
            with(
              package,
              stack,
              mem,
              disk,
              config,
              an_instance_of(CloudController::Blobstore::UrlGenerator)).
            and_return(staging_message)
          allow(stager_task).to receive(:stage).and_yield(staging_result).and_return('fake-stager-response')
        end

        let(:buildpack) { Buildpack.make(name: 'buildpack-name') }
        let(:buildpack_key) { buildpack.key }
        let(:buildpack_guid) { buildpack.guid }

        let(:package) { PackageModel.make }
        let(:droplet) { DropletModel.make }
        let(:app) { package }

        it 'stages the package with a stager task' do
          stager.stage_package(droplet, stack, mem, disk)
          expect(stager_task).to have_received(:stage).with(staging_message, droplet.guid)
          expect(PackageStagerTask).to have_received(:new).
            with(
              config,
              message_bus,
              dea_pool,
              stager_pool,
              an_instance_of(CloudController::Blobstore::UrlGenerator))
        end

        it 'updates the droplet to a STAGED state' do
          stager.stage_package(droplet, stack, mem, disk)
          expect(droplet.refresh.state).to eq(DropletModel::STAGED_STATE)
        end

        it 'updates the droplet with the detected buildpack' do
          stager.stage_package(droplet, stack, mem, disk)
          expect(droplet.refresh.buildpack_guid).to eq(buildpack_guid)
        end

        context 'when staging fails' do
          it 'raises an ApiError' do
            allow(stager_task).to receive(:stage).and_raise(PackageStagerTask::FailedToStage, 'a staging error message')

            expect { stager.stage_package(droplet, stack, mem, disk) }.
              to raise_error(VCAP::Errors::ApiError, /a staging error message/)
          end
        end
      end
    end
  end
end
