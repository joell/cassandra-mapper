require 'active_support/concern'

module CassandraMapper
  module EmbeddedDocument
    module Dirty
      extend ActiveSupport::Concern

      included do
        # assigned to a lambda by the root document that notifies it that its 
        #   embed is about to change
        attr_accessor :embed_will_change
      end

      def attribute_will_change!(name)
        embed_will_change.call  if embed_will_change
        super
      end
    end
  end
end
