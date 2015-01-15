Sequel.migration do
  change do
    create_table :v3_droplets do
      VCAP::Migration.common(self)
      String :state, null: false
      String :buildpack_guid
      String :droplet_hash
    end
  end
end
