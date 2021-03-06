require 'active_support/concern'

require 'cassandra_mapper/cassandra'

module CassandraMapper
  module Versioning
    module Persistence
      extend ActiveSupport::Concern

      LONG_ZERO = Cassandra::Long.new(0).to_s

      included do
        before_save    :save_zombie
        before_destroy :save_zombie
        after_save     :post_save_zombie
        after_destroy  :deactivate

        property :_num_versions, Integer, :default => 0
      end

      module InstanceMethods
        # execute a block that saves the document without the changes being versioned
        def without_versioning
          @without_versioning = true
          result = yield
          @without_versioning = false
          result
        end

        def permanently_destroy
          @without_versioning = true

          # destroy the zombies
          CassandraMapper.client.get(self.class.zombie_family, key).values.each  do |zombie_key|
            obliterate_zombie(zombie_key)
          end
          # destroy the zombie record
          CassandraMapper.client.remove(self.class.zombie_family, key)

          # destroy the active document itself
          _run_obliterate_callbacks  do
            destroy
          end
        end

        def save(write_key = key, *args)
          self.version += 1

          @overwrite_key = write_key  if write_key != key
          result = super(write_key, *args)
          @overwrite_key = nil

          result
        end

        private
        def _run_obliterate_callbacks(zombie_parent = nil)
          self.class._obliterate_callbacks.each  do |callback|
            self.send(callback, zombie_parent)
          end

          yield
        end

        # Permanently remove a zombie from the class's column family.
        def obliterate_zombie(key)
          obliterate = lambda do
            CassandraMapper.client.remove(self.class.column_family, key)
          end

          if !self.class._obliterate_callbacks.empty? && !(zombie = self.class.find(key)).nil?
            zombie.freeze.send(:_run_obliterate_callbacks, self, &obliterate)
          else
            obliterate.call
          end
        end

        # TODO: This function is obscenely large and should be broken down.
        def save_zombie(*args)
          key = self.key
          without_versioning = @without_versioning
          _raw_columns = self._raw_columns

          # handle the special case of overwriting a different document
          if !without_versioning && @overwrite_key
            cf = self.class.column_family
            _raw_columns = CassandraMapper.client.get(cf, @overwrite_key)
            if _raw_columns.empty?    # does the target document no longer exists?
              without_versioning = true
            else
              key = @overwrite_key
              self.version = deserialize_value(_raw_columns["version"], Integer) + 1
            end
          end

          now = Time.stamp

          #   Temporarily create lifespan timestamp attributes to get them
          # into the db.
          if new? || !without_versioning
            # TODO: This is a nasty hack, but it works for now.  What we really
            #   need is a framework for internal, non-model-visible
            #   attribtes/properties.
            self.class.properties["birth_timestamp"] = {:type => Time}
            self.send(:attribute=, "birth_timestamp", now)
            self.class.properties.delete("birth_timestamp")

            # maximum-value timestamp for death is interpreted as "alive"
            max_long = Cassandra::Long.new("\x7f\xff\xff\xff\xff\xff\xff\xff")
            @attributes[:death_timestamp] = max_long.to_s  if new?
          end

          # if appropriate, retain a copy of the current version of the document
          unless without_versioning || new?
            # save a copy of the old version of the document (a zombie)
            zombie_key = generate_key
            _raw_columns["active_version_key"] = key
            _raw_columns["death_timestamp"]    = serialize_value(now)
            CassandraMapper.client.insert(self.class.column_family, zombie_key,
                                          _raw_columns)

            # add a zombie entry for the new doc mapped to this one's pre-save timestamp
            cols = {LONG_ZERO => version_group,
                    Cassandra::Long.new(timestamp).to_s => zombie_key}
            CassandraMapper.client.insert(self.class.zombie_family, key, cols)

            if not @overwrite_key
              self._num_versions += 1
              # remove all zombies that exceed our maximum
              if self._num_versions > self.class.max_versions
                surplus = self._num_versions - self.class.max_versions
                # get the entry for the outdated zombies
                outdated = CassandraMapper.client.get(self.class.zombie_family, key,
                                                      :start => 1, :count => surplus)
                outdated.each do |col, k|
                  # remove the zombie from our record
                  CassandraMapper.client.remove(self.class.zombie_family, key, col)
                  # destroy the zombie
                  obliterate_zombie(k)
                end

                self._num_versions = self.class.max_versions
              end
            end

            # save the old timestamp for when we update the "active" record post-save
            @_old_timestamp = timestamp
          end
          true
        end

        def post_save_zombie
          # If we overwrote a different document, then we must keep the
          #   old-versions count consistent.
          if @overwrite_key
            # NOTE: We subtract one for the grouping-index column 0.
            self._num_versions = CassandraMapper.client.count_columns(self.class.zombie_family, key)-1
          end

          # Update this doc's timestamp entry from the `actives' family after
          # it was saved and we have the new timestamp.
          unless @without_versioning
            # remove the temporary lifespan timestamp attributes; they must exist
            #   only in the db and should not be visible in the model
            @attributes.delete(:birth_timestamp)
            @attributes.delete(:death_timestamp)

            # remove the old timestamp entry
            deactivate(@_old_timestamp)  unless new?
            # write a new timestamp entry
            active_since = Cassandra::Long.new(timestamp).to_s
            CassandraMapper.client.insert(self.class.actives_family, version_group,
                                          {active_since => {key => ""}})
          end
          true
        end

        # Remove this doc's timestamp entry from the `actives' family.
        def deactivate(stamp = timestamp)
          active_since = Cassandra::Long.new(stamp).to_s
          CassandraMapper.client.remove(self.class.actives_family, version_group,
                                        active_since, key)
          true
        end

        def version_group
          field = self.class.version_group_field
          field ? serialize_value(attributes[field]) : "\0"
        end

        def deserialize_value(*args)
          CassandraMapper::Serialization.deserialize_value(*args)
        end

        def serialize_value(*args)
          CassandraMapper::Serialization.serialize_value(*args)
        end
      end
    end
  end
end
