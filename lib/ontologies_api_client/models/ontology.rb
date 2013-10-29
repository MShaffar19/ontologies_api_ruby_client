require 'cgi'
require_relative "../base"

module LinkedData
  module Client
    module Models
      class Ontology < LinkedData::Client::Base
        include LinkedData::Client::Collection
        include LinkedData::Client::ReadWrite

        @media_type = "http://data.bioontology.org/metadata/Ontology"
        @include_attrs    = "all"

        def flat?
          self.flat
        end

        def private?
          viewingRestriction && viewingRestriction.downcase.eql?("private")
        end

        def licensed?
          viewingRestriction && viewingRestriction.downcase.eql?("licensed")
        end

        def viewing_restricted?
          private? && licensed?
        end

        def view?
          viewOf && viewOf.length > 1
        end

        def purl
          if self.acronym
            "#{LinkedData::Client.settings.purl_prefix}/#{acronym}"
          else
            ""
          end
        end

        def admin?(user)
          return false if user.nil?
          return true if user.admin?
          return administeredBy.any? {|u| u == user.id}
        end

        # For use with select lists, always includes the admin by default
        def acl_select
          select_opts = []
          return select_opts if self.acl.nil? or self.acl.empty?

          if self.acl.nil? || self.acl.empty?
            self.administeredBy.each do |userId|
              select_opts << [User.get(userId).username, userId]
            end
          else
            self.acl.each do |userId|
              select_opts << [User.get(userId).username, userId]
            end
          end

          (select_opts + self.administeredBy).uniq
        end

        ##
        # Find a resource by a combination of attributes
        # Override to search for views as well by default
        # Views get hidden on the REST service unless the `include_views`
        # parameter is set to `true`
        def self.find_by(attrs, *args)
          params = args.shift
          if params.is_a?(Hash)
            params[:include_views] = params[:include_views] || true
          else
            # Stick params back and create a new one
            args.push({include_views: true})
          end
          args.unshift(params)
          super(attrs, *args)
        end

        ##
        # Find a resource by id
        # Override to search for views as well by default
        # Views get hidden on the REST service unless the `include_views`
        # parameter is set to `true`
        def find(id, params = {})
          params[:include_views] = params[:include_views] || true
          super(id, params)
        end

      end
    end
  end
end
