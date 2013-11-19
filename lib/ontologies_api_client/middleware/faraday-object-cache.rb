require 'digest/sha1'
require 'active_support/cache'
require 'lz4-ruby'
require_relative '../http'

module Faraday
  ##
  # This middleware causes Faraday to return

  class ObjectCacheResponse < Faraday::Response
    attr_accessor :parsed_body
  end

  class ObjectCache < Faraday::Middleware
    def initialize(app, *arguments)
      super(app)

      if arguments.last.is_a? Hash
        options = arguments.pop
        @logger = options.delete(:logger)
      else
        options = arguments
      end

      @store = options[:store] || ActiveSupport::Cache.lookup_store(store, options)
    end

    def call(env)
      # Add if newer than last modified statement to headers
      request_key = cache_key_for(create_request(env))
      last_modified_key = "LM::#{request_key}"
      last_retrieved_key = "LR::#{request_key}"

      # If we made the last request within the expiry
      if cache_exist?(last_retrieved_key) && cache_exist?(request_key)
        puts "DEBUG not expired #{env[:url].to_s}" if $CACHE_DEBUG
        cached_item = cache_read(request_key)
        ld_obj = cached_item.is_a?(Hash) && cached_item.key?(:ld_obj) ? cached_item[:ld_obj] : cached_item
        env[:status] = 304
        cached_response = ObjectCacheResponse.new(env)
        cached_response.parsed_body = ld_obj
        return cached_response
      end

      last_modified = cache_read(last_modified_key)
      headers = env[:request_headers]
      puts "DEBUG last modified: " + last_modified.to_s if last_modified && $CACHE_DEBUG
      headers['If-Modified-Since'] = last_modified if last_modified

      @app.call(env).on_complete do |response_env|
        # Only cache get and head requests
        if [:get, :head].include?(response_env[:method])
          puts "DEBUG response status: " + response_env[:status].to_s if $CACHE_DEBUG

          last_modified = response_env[:response_headers]["Last-Modified"]

          # Generate key using header hash
          key = request_key

          # If the last retrieve time is less than expiry
          if response_env[:status] == 304 && cache_exist?(key)
            stored_obj = cache_read(key)

            # Update if last modified is different
            if stored_obj[:last_modified] != last_modified
              puts "UPDATING CACHE #{response_env[:url].to_s}" if $CACHE_DEBUG
              stored_obj[:last_modified] = last_modified
              cache_write(last_modified_key, last_modified)
              cache_write(key, stored_obj)
            end

            ld_obj = stored_obj[:ld_obj]
          else
            if response_env[:body].nil? || response_env[:body].empty?
              # We got here with an empty body, meaning the object wasn't
              # in the cache (weird). So re-do the request.
              puts "REDOING REQUEST NO CACHE ENTRY #{response_env[:url].to_s}"
              env[:request_headers].delete("If-Modified-Since")
              response_env = @app.call(env).env
            end
            ld_obj = LinkedData::Client::HTTP.object_from_json(response_env[:body])
            expiry = response_env[:response_headers]["Cache-Control"].to_s.split("max-age=").last.to_i
            if expiry > 0 && last_modified
              # This request is cacheable, store it
              puts "STORING OBJECT: #{response_env[:url].to_s}" if $CACHE_DEBUG
              stored_obj = {last_modified: last_modified, ld_obj: ld_obj}
              cache_write(last_modified_key, last_modified)
              cache_write(last_retrieved_key, true, expires_in: expiry)
              cache_write(key, stored_obj)
            end
          end

          response = ObjectCacheResponse.new(response_env)
          response.parsed_body = ld_obj
          return response
        end
      end
    end

    private

    def cache_write(key, obj, *args)
      result = @store.write(key, obj, *args)

      if result
        return result
      else
        # This should still get stored in memcache
        # keep it in memory, though, because
        # marshal/unmarshal is too slow.
        # This way memcache will act as a backup
        # and you load from there if it isn't
        # in memory yet.
        @large_object_cache ||= {}
        @large_object_cache[key] = obj
        cache_write_compressed(key, obj, *args)
        return true
      end
    end

    def cache_read(key)
      obj = @store.read(key)
      return if obj.nil?
      if obj.is_a?(CompressedMemcache)
        # Try to get from the large object cache
        large_obj = @large_object_cache[key] if @large_object_cache
        # Fallback to the memcache version
        large_obj ||= cache_read_compressed(key)
        obj = large_obj
      end
      obj.dup
    end

    def cache_exist?(key)
      @store.exist?(key)
    end

    class MultiMemcache; attr_accessor :parts, :key; end
    class CompressedMemcache; attr_accessor :key; end

    ##
    # This wraps memcache in a method that will split large objects
    # for storage in multiple keys to get around memcache limits on
    # value size. The corresponding cache_read_multi will read out
    # the objects.
    def cache_write_multi(key, obj, *args)
      lock_key = "lock:#{key}"
      puts "\n\n\n\n\nLOCKED !!! !!!\n\n\n\n\n" if @store.read(lock_key)
      return if @store.read(lock_key)
      begin
        @store.write(lock_key, true)
        dump = Marshal.dump(obj)
        chunk = 1_000_000
        mm = MultiMemcache.new
        parts = []
        part_count = (dump.bytesize / chunk) + 1
        position = 0
        part_count.times do
          parts << dump[position..position+chunk-1]
          position += chunk
        end
        mm.parts = parts.length
        mm.key = Digest::SHA1.hexdigest(dump)
        parts.each_with_index {|p,i| @store.write("#{mm.key}:p#{i}", p, *args)}
        @store.write(key, mm, *args)
      rescue Exception
        parts.each_with_index {|p,i| @store.delete("#{mm.key}:p#{i}")} if parts
        @store.delete(key) if key
      ensure
        @store.delete(lock_key)
      end
    end

    ##
    # Read out a multipart cache object
    def cache_read_multi(key)
      obj = @store.read(key)
      if obj.is_a?(MultiMemcache)
        keys = []
        obj.parts.times do |i|
          keys << "#{obj.key}:p#{i}"
        end
        parts = @store.read_multi(keys).values.join
        obj = Marshal.load(parts)
      end
      obj
    end

    ##
    # Compress cache entry
    def cache_write_compressed(key, obj, *args)
      compressed = LZ4::compress(Marshal.dump(obj))
      return if compressed.nil?
      placeholder = CompressedMemcache.new
      placeholder.key = "#{key}::#{(Time.now.to_f * 1000).to_i}::LZ4"
      begin
        @store.write(key, placeholder)
        @store.write(placeholder.key, compressed)
      rescue
        @store.delete(key)
        @store.delete(placeholder.key)
      end
    end

    ##
    # Read compressed cache entry
    def cache_read_compressed(key)
      obj = @store.read(key)
      if obj.is_a?(CompressedMemcache)
        begin
          uncompressed = LZ4::uncompress(@store.read(obj.key))
          obj = Marshal.load(uncompressed)
        rescue StandardError => e
          # There is a problem with the stored value, let's remove it so we don't get the error again
          @store.delete(key)
          @store.delete(obj.key)
          raise e
        end
      end
      obj
    end


    # Internal: Generates a String key for a given request object.
    # The request object is folded into a sorted Array (since we can't count
    # on hashes order on Ruby 1.8), encoded as JSON and digested as a `SHA1`
    # string.
    #
    # Returns the encoded String.
    def cache_key_for(request)
      array = request.stringify_keys.to_a.sort
      Digest::SHA1.hexdigest(Marshal.dump(array))
    end

    # Internal: Creates a new 'Hash' containing the request information.
    #
    # env - the environment 'Hash' from the Faraday stack.
    #
    # Returns a 'Hash' containing the ':method', ':url' and 'request_headers'
    # entries.
    def create_request(env)
      request = env.to_hash.slice(:method, :url, :request_headers)
      request[:request_headers] = request[:request_headers].dup
      request
    end

    def clean_request_headers(request)
      request[:request_headers].delete("If-Modified-Since")
      request[:request_headers].delete("Expect")
      request
    end

  end
end

if Faraday.respond_to?(:register_middleware)
  Faraday.register_middleware object_cache: Faraday::ObjectCache
elsif Faraday::Middleware.respond_to?(:register_middleware)
  Faraday::Middleware.register_middleware object_cache: Faraday::ObjectCache
end
