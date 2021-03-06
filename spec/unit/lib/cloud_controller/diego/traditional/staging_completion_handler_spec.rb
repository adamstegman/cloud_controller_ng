require 'spec_helper'

module VCAP::CloudController
  describe Diego::Traditional::StagingCompletionHandler do
    let(:environment) { {} }
    let(:staged_app) { App.make(instances: 3, staging_task_id: 'the-staging-task-id', environment_json: environment) }
    let(:logger) { instance_double(Steno::Logger, info: nil, error: nil, warn: nil) }
    let(:app_id) { staged_app.guid }
    let(:buildpack) { Buildpack.make }

    let(:success_response) do
      {
        'app_id' => app_id,
        'task_id' => staged_app.staging_task_id,
        'detected_buildpack' => 'INTERCAL',
        'buildpack_key' => buildpack.key,
        'execution_metadata' => '{command: [' ']}',
        'detected_start_command' => { 'web' => '' },
      }
    end

    let(:malformed_success_response) do
      success_response.except('detected_buildpack')
    end

    let(:fail_response) do
      {
        'app_id' => app_id,
        'task_id' => staged_app.staging_task_id,
        'error' => { 'id' => 'NoCompatibleCell', 'message' => 'Found no compatible cell' }
      }
    end

    let(:malformed_fail_response) do
      fail_response.except('task_id')
    end

    let(:runner) do
      instance_double(Diego::Runner, start: nil)
    end

    let(:runners) { instance_double(Runners, runner_for_app: runner) }

    subject { Diego::Traditional::StagingCompletionHandler.new(runners) }

    before do
      allow(Steno).to receive(:logger).with('cc.stager').and_return(logger)
      allow(Dea::Client).to receive(:start)

      staged_app.add_new_droplet('lol')
    end

    def handle_staging_result(response)
      subject.staging_complete(response)
    end

    describe 'success cases' do
      it 'marks the app as staged' do
        expect {
          handle_staging_result(success_response)
        }.to change { staged_app.reload.staged? }.to(true)
      end

      context 'when staging metadata is returned' do
        before do
          success_response['execution_metadata'] = 'some-metadata'
          success_response['detected_start_command']['web'] = 'some-command'
        end

        it 'updates the droplet with the returned start command' do
          handle_staging_result(success_response)
          staged_app.reload
          droplet = staged_app.current_droplet
          expect(droplet.execution_metadata).to eq('some-metadata')
          expect(droplet.detected_start_command).to eq('some-command')
          expect(droplet.droplet_hash).to eq('lol')
        end
      end

      context 'when running in diego is not enabled' do
        it 'starts the app instances' do
          expect(runners).to receive(:runner_for_app) do |received_app|
            expect(received_app.guid).to eq(app_id)
            runner
          end
          expect(runner).to receive(:start)
          handle_staging_result(success_response)
        end

        it 'logs the staging result' do
          handle_staging_result(success_response)
          expect(logger).to have_received(:info).with('diego.staging.finished', response: success_response)
        end

        it 'should update the app with the detected buildpack' do
          handle_staging_result(success_response)
          staged_app.reload
          expect(staged_app.detected_buildpack).to eq('INTERCAL')
          expect(staged_app.detected_buildpack_guid).to eq(buildpack.guid)
        end
      end

      context 'when running in diego is enabled' do
        let(:environment) { { 'DIEGO_RUN_BETA' => 'true' } }

        it 'desires the app using the diego client' do
          expect(runners).to receive(:runner_for_app) do |received_app|
            expect(received_app.guid).to eq(app_id)
            runner
          end
          expect(runner).to receive(:start)
          handle_staging_result(success_response)
        end
      end
    end

    describe 'failure cases' do
      context 'when the staging fails' do
        it "should mark the app as 'failed to stage'" do
          handle_staging_result(fail_response)
          expect(staged_app.reload.package_state).to eq('FAILED')
        end

        it 'records the error' do
          handle_staging_result(fail_response)
          expect(staged_app.reload.staging_failed_reason).to eq('NoCompatibleCell')
        end

        it 'should emit a loggregator error' do
          expect(Loggregator).to receive(:emit_error).with(staged_app.guid, /Found no compatible cell/)
          handle_staging_result(fail_response)
        end

        it 'should not start the app instance' do
          expect(Dea::Client).not_to receive(:start)
          handle_staging_result(fail_response)
        end

        it 'should not update the app with the detected buildpack' do
          handle_staging_result(fail_response)
          staged_app.reload
          expect(staged_app.detected_buildpack).not_to eq('INTERCAL')
          expect(staged_app.detected_buildpack_guid).not_to eq(buildpack.guid)
        end
      end

      context 'when staging references an unknown app' do
        let(:app_id) { 'ooh ooh ah ah' }

        before do
          handle_staging_result(success_response)
        end

        it 'should not attempt to start anything' do
          expect(runner).not_to have_received(:start)
          expect(Dea::Client).not_to have_received(:start)
        end

        it 'logs info for the CF operator since the app may have been deleted by the CF user' do
          expect(logger).to have_received(:error).with('diego.staging.unknown-app', response: success_response)
        end
      end

      context 'when the task_id is invalid' do
        before do
          success_response['task_id'] = 'another-task-id'
          handle_staging_result(success_response)
        end

        it 'should not attempt to start anything' do
          expect(runner).not_to have_received(:start)
          expect(Dea::Client).not_to have_received(:start)
        end

        it 'logs info for the CF operator since the user may have attempted a second concurrent push and returns' do
          expect(logger).to have_received(:warn).with('diego.staging.not-current', response: success_response, current: staged_app.staging_task_id)
        end
      end

      context 'with a malformed success message' do
        before do
          expect {
            handle_staging_result(malformed_success_response)
          }.to raise_error(VCAP::Errors::ApiError)
        end

        it 'should not start anything' do
          expect(Dea::Client).not_to have_received(:start)
        end

        it 'logs an error for the CF operator' do
          expect(logger).to have_received(:error).with('diego.staging.invalid-message', payload: malformed_success_response, error: '{ detected_buildpack => Missing key }')
        end
      end

      context 'with a malformed error message' do
        it 'should not emit any loggregator messages' do
          expect(Loggregator).not_to receive(:emit_error).with(staged_app.guid, /bad/)
          handle_staging_result(malformed_fail_response)
        end
      end

      context 'when updating the app record with data from staging fails' do
        let(:save_error) { StandardError.new('save-error') }

        before do
          allow_any_instance_of(App).to receive(:save_changes).and_raise(save_error)
        end

        it 'should not start anything' do
          handle_staging_result(success_response)

          expect(runners).not_to have_received(:runner_for_app)
          expect(runner).not_to have_received(:start)
        end

        it 'logs an error for the CF operator' do
          handle_staging_result(success_response)

          expect(logger).to have_received(:error).with(
            'diego.staging.saving-staging-result-failed',
            response: success_response,
            error: 'save-error',
          )
        end
      end
    end
  end
end
