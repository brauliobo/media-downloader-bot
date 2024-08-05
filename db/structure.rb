Sequel.migration do
  change do
    create_table(:schema_migrations) do
      String :filename, :text=>true, :null=>false
      
      primary_key [:filename]
    end
    
    create_table(:sessions) do
      primary_key :uid, :type=>:Bignum
      String :invoice
      String :daylog
      Integer :msg_count, :default=>0
      DateTime :created_at, :default=>Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, :default=>Sequel::CURRENT_TIMESTAMP
    end
  end
end
