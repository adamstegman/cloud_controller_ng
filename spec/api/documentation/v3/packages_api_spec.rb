require 'spec_helper'
require 'awesome_print'
require 'rspec_api_documentation/dsl'

resource 'Packages (Experimental)', type: :api do
  let(:tmpdir) { Dir.mktmpdir }
  let(:valid_zip) {
    zip_name = File.join(tmpdir, 'file.zip')
    TestZip.create(zip_name, 1, 1024)
    File.new(zip_name)
  }

  let(:user) { VCAP::CloudController::User.make }
  let(:user_header) { headers_for(user)['HTTP_AUTHORIZATION'] }
  header 'AUTHORIZATION', :user_header

  def do_request_with_error_handling
    do_request
    if response_status == 500
      error = MultiJson.load(response_body)
      ap error
      raise error['description']
    end
  end

  context 'standard endpoints' do
    get '/v3/packages/:guid' do
      let(:space) { VCAP::CloudController::Space.make }
      let(:package_model) do
        VCAP::CloudController::PackageModel.make(space_guid: space_guid)
      end

      let(:guid) { package_model.guid }
      let(:space_guid) { space.guid }

      before do
        space.organization.add_user user
        space.add_developer user
      end

      example 'Get a Package' do
        expected_response = {
          'type'       => package_model.type,
          'guid'       => guid,
          'hash'       => nil,
          'state'      => VCAP::CloudController::PackageModel::CREATED_STATE,
          'url'        => nil,
          'error'      => nil,
          'created_at' => package_model.created_at.as_json,
          '_links'     => {
            'self'   => { 'href' => "/v3/packages/#{guid}" },
            'upload' => { 'href' => "/v3/packages/#{guid}/upload" },
            'space'  => { 'href' => "/v2/spaces/#{space_guid}" },
          }
        }

        do_request_with_error_handling

        parsed_response = MultiJson.load(response_body)
        expect(response_status).to eq(200)
        expect(parsed_response).to match(expected_response)
      end
    end

    post '/v3/packages/:guid/upload' do
      let(:type) { 'bits' }
      let!(:package_model) do
        VCAP::CloudController::PackageModel.make(space_guid: space_guid, type: type)
      end
      let(:space) { VCAP::CloudController::Space.make }
      let(:space_guid) { space.guid }
      let(:guid) { package_model.guid }

      before do
        space.organization.add_user(user)
        space.add_developer(user)
      end

      parameter :bits, 'A binary zip file containing the package bits', required: true

      let(:packages_params) do
        {
          bits_name: 'application.zip',
          bits_path: "#{tmpdir}/application.zip",
        }
      end

      let(:request_body_example) do
        <<-eos.gsub(/^ */, '')
          Content-type: multipart/form-data, boundary=AaB03x
          --AaB03x
          Content-Disposition: form-data; name="type"

          #{type}
          --AaB03x
          Content-Disposition: form-data; name="bits"; filename="application.zip"
          Content-Type: application/zip
          Content-Length: 123
          Content-Transfer-Encoding: binary

          &lt;&lt;binary artifact bytes&gt;&gt;
          --AaB03x
        eos
      end

      example 'Upload Bits for a Package of type bits' do
        expect { do_request packages_params }.to change { Delayed::Job.count }.by(1)

        job = Delayed::Job.last
        expect(job.handler).to include(package_model.guid)
        expect(job.guid).not_to be_nil

        expected_response = {
          'guid'       => guid,
          'type'       => type,
          'hash'       => nil,
          'state'      => VCAP::CloudController::PackageModel::PENDING_STATE,
          'url'        => nil,
          'error'      => nil,
          'created_at' => package_model.created_at.as_json,
          '_links'     => {
            'self'   => { 'href' => "/v3/packages/#{package_model.guid}" },
            'upload' => { 'href' => "/v3/packages/#{package_model.guid}/upload" },
            'space'  => { 'href' => "/v2/spaces/#{space_guid}" },
          }
        }

        parsed_response = MultiJson.load(response_body)
        expect(response_status).to eq(201)
        expect(parsed_response).to match(expected_response)
      end
    end

    post '/v3/apps/:guid/packages' do
      let(:space) { VCAP::CloudController::Space.make }
      let(:space_guid) { space.guid }
      let(:app_model) { VCAP::CloudController::AppModel.make(space_guid: space_guid) }
      let(:guid) { app_model.guid }
      let(:type) { 'docker' }
      let(:url) { 'docker://cloudfoundry/runtime-ci' }
      let(:packages_params) do
        {
          type: type,
          url:  url
        }
      end

      before do
        space.organization.add_user(user)
        space.add_developer(user)
      end

      let(:raw_post) { MultiJson.dump(packages_params, pretty: true) }

      parameter :type, 'Package type', required: true, valid_values: ['bits', 'docker']
      parameter :url, 'Url of docker image', required: false

      example 'Create a Package' do
        expect {
          do_request packages_params
        }.to change { VCAP::CloudController::PackageModel.count }.by(1)

        package = VCAP::CloudController::PackageModel.last

        expected_response = {
          'guid'       => package.guid,
          'type'       => type,
          'hash'       => nil,
          'state'      => 'READY',
          'error'      => nil,
          'url'        => url,
          'created_at' => package.created_at.as_json,
          '_links'     => {
            'self'   => { 'href' => "/v3/packages/#{package.guid}" },
            'upload' => { 'href' => "/v3/packages/#{package.guid}/upload" },
            'space'  => { 'href' => "/v2/spaces/#{space_guid}" },
          }
        }

        parsed_response = MultiJson.load(response_body)
        expect(response_status).to eq(201)
        expect(parsed_response).to match(expected_response)
      end
    end

    post '/v3/packages/:guid/droplets' do
      parameter :buildpack, 'Buildpack used to stage package', required: false
      parameter :staging_environment_variables, 'Environment variables to use during staging', required: false
      parameter :stack, 'Stack used to stage package', required: false
      parameter :memory_limit, 'Memory limit used to stage package', required: false
      parameter :disk_limit, 'Buildpack used to stage package', required: false

      let(:space) { VCAP::CloudController::Space.make }
      let(:space_guid) { space.guid }
      let!(:package_model) do
        VCAP::CloudController::PackageModel.make(space_guid: space_guid)
      end
      let(:guid) { package_model.guid }

      let(:stager_id) { 'abc123' }
      let(:stager_subject) { "staging.#{stager_id}.start" }
      let(:advertisment) do
        {
          'id' => stager_id,
          'stacks' => ['default-stack-name'],
          'available_memory' => 2048,
          'app_id_to_count' => {},
        }
      end
      let(:message_bus) { VCAP::CloudController::Config.message_bus }

      before do
        space.organization.add_user(user)
        space.add_developer(user)
        allow(EM).to receive(:add_timer)
        allow(EM).to receive(:defer).and_yield
        allow(EM).to receive(:schedule_sync) do |&blk|
          blk.call
        end
      end

      example do
        VCAP::CloudController::Dea::Client.dea_pool.register_subscriptions
        message_bus.publish('dea.advertise', advertisment)
        message_bus.publish('staging.advertise', advertisment)

        expect {
          do_request_with_error_handling
        }.to change { VCAP::CloudController::DropletModel.count }.by(1)

        droplet = VCAP::CloudController::DropletModel.last
        expected_response = {
          'guid' => droplet.guid,
          'state' => 'PENDING',
          'hash' => nil,
          'created_at' => droplet.created_at.as_json,
          '_links'     => {
            'self'   => { 'href' => "/v3/droplets/#{droplet.guid}" },
          }
        }

        expect(response_status).to eq(201)

        parsed_response = MultiJson.load(response_body)
        expect(parsed_response).to eq(expected_response)
        message = message_bus.published_messages.last
        expect(message[:subject]).to eq('staging.abc123.start')
        expect(message[:message][:app_id]).to eq(guid)
        expect(message[:message][:task_id]).to eq(droplet.guid)
      end
    end

    delete '/v3/packages/:guid' do
      let(:space) { VCAP::CloudController::Space.make }
      let(:space_guid) { space.guid }
      let!(:package_model) do
        VCAP::CloudController::PackageModel.make(space_guid: space_guid)
      end

      let(:guid) { package_model.guid }

      before do
        space.organization.add_user user
        space.add_developer user
      end

      example 'Delete a Package' do
        expect {
          do_request_with_error_handling
        }.to change { VCAP::CloudController::PackageModel.count }.by(-1)
        expect(response_status).to eq(204)
      end
    end
  end
end

def stub_schedule_sync(&before_resolve)
  allow(EM).to receive(:schedule_sync) do |&blk|
    promise = VCAP::Concurrency::Promise.new

    begin
      if blk.arity > 0
        blk.call(promise)
      else
        promise.deliver(blk.call)
      end
    rescue => e
      promise.fail(e)
    end

    # Call before_resolve block before trying to resolve the promise
    before_resolve.call

    promise.resolve
  end
end
