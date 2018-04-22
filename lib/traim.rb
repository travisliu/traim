require 'json'
require 'rack'
require 'seg'
require 'yaml'
require 'logger'
require 'active_record'

class Traim 
  DEFAULT_HEADER = {"Content-Type" => 'application/json;charset=UTF-8'}
  TRAIM_ENV = ENV['TRAIM_ENV'] || 'development'

  def initialize(&block)
    if self.class.logger == nil
      self.class.logger = Logger.new(STDOUT)
      self.class.logger.level = Logger::INFO
    end

    @app = Application.new
    @app.compile(&block)
  end

  def self.settings; @settings ||= {} end

  def self.application(&block)
    @instance = new(&block) 
  end

  def self.logger=(logger); @logger = logger end
  def self.logger; @logger end

  def self.call(env)
    @instance.dup.call(env)
  end

  def self.config(&block)
    config_file = YAML.load_file("#{Dir.pwd}/config/database.yml")
    ActiveRecord::Base.establish_connection(config_file[TRAIM_ENV])
    yield self 
  end

  def logger; Traim.logger end

  def call(env)
    request = Rack::Request.new(env)
    logger.info("#{request.request_method} #{request.path_info} from #{request.ip}")
    logger.debug("Parameters: #{request.params}")
    
    @app.route(request)
  rescue Error => e
    logger.error(e) 
    [e.status, e.header, [JSON.dump(e.body)]]
  rescue Exception => e
    logger.error(e) 
    error = Error.new
    [error.status, error.header, [JSON.dump(error.body)]]
  end

  class Application 
    def logger; Traim.logger end 

    def initialize(name = :default)
      @name         = name
      @resources    = {}
      @applications = {}
    end

    def resources(name, &block)
      @resources[name] = Resource.new(block) 
    end

    def namespace(name, &block)
      logger.debug("application namespace #{name}")
      application(name).compile(&block)
    end

    def application(name = :default)
      logger.debug("Lunch application #{name}")
      app = @applications[name] ||= Application.new(name)
    end

    def helpers(&block)
      @helpers_block = block
    end

    def route(request, seg = nil)
      inbox = {}
      seg ||= Seg.new(request.path_info) 
      seg.capture(:segment, inbox)
      segment = inbox[:segment].to_sym

      if app = @applications[segment]
        app.route(request, seg)
      else 
        router = Router.new(@resources)
        router.instance_eval(&@helpers_block) unless @helpers_block.nil?
        router.run(seg, inbox)
        router.render(request)
      end
    end

    def compile(&block)
      logger.debug("Compile application: #{@name}")
      instance_eval(&block)
    end
  end

  class Error < StandardError

    def initialize(options = {})
      @message = options[:message] || error_message 
      @body    = options[:body]    || error_message
      super(@message)
    end

    def status; 500 end
    def error_message; 'Internal Server Error' end
    def header; DEFAULT_HEADER end
    def body; {message: @body} end
  end
  class NotImplementedError < Error
    def error_message; "Not Implemented Error" end
    def status; 501 end
  end
  class BadRequestError < Error
    def error_message; "Bad Request Error" end
    def status; 400 end
  end
  class NotFoundError < Error
    def error_message; "Not Found Error" end
    def status; 404 end
  end
   
  class Router

    def status; @status || ok end
    def logger; Traim.logger  end 

    # status code sytax suger
    def ok;        @status = 200 end
    def created;   @status = 201 end
    def no_cotent; @status = 204 end

    def headers(key, value)
      @headers[key] = value 
    end

    def initialize(resources) 
      @status    = nil
      @resources = resources
      @headers   = {}
    end

    def self.resources; @resources ||= {} end

    def resources(name)
      @resources[name]
    end

    def show(&block);    @resource.action(:show,    &block) end
    def create(&block);  @resource.action(:create,  &block) end
    def update(&block);  @resource.action(:update,  &block) end
    def destory(&block); @resource.action(:destory, &block) end

    def run(seg, inbox)  
      begin
        segment = inbox[:segment].to_sym

        if @resource.nil?
          raise BadRequestError unless @resource = resources(segment)
          next
        end 

        if @id.nil? && !defined?(@collection_name)
          if collection = @resource.collections[segment]
            @collection_name = segment
            return instance_eval(&collection)
          else
            @id = segment.to_s.to_i
            @record = @resource.model_delegator.show(@id)
            next 
          end
        end

        if !defined?(@member_name)
          if member = @resource.members[segment]
            @member_name = segment
            return instance_eval(&member)
          end
        end

        raise BadRequestError 
      end while seg.capture(:segment, inbox) 
    end
    
    def to_json
      if @result.kind_of?(ActiveRecord::Relation)
        hash = @result.map do |object|
          @resource.to_hash(object, @resources) 
        end
        JSON.dump(hash)
      else
        new_hash = {}
        if @result.errors.size == 0
          new_hash = @resource.to_hash(@result, @resources)
        else
          new_hash = @result.errors.messages
        end
        JSON.dump(new_hash)
      end
    end

    def action(name)
      raise NotImplementedError unless action = @resource.actions[name] 

      action[:block] = default_actions[name] if action[:block].nil?
      action
    end

    def default_actions
      @default_actions ||= begin 
        actions = {}
        delegator = @resource.model_delegator
        actions["POST"] = lambda do |params|
          delegator.create(params["payload"])
        end
        actions["GET"] = lambda do |params|
          delegator.show(params["id"])
        end
        actions["PUT"] = lambda do |params|
          result = delegator.update(params["id"], params["payload"])
          result
        end
        actions["DELETE"] = lambda do |params|
          delegator.delete(@id)
        end
        actions
      end
    end

    def model;  @resource.model end
    def record; @record; end

    def render(request)
      method_block = action(request.request_method)
      payload = request.params
      if (method_block[:options][:permit])
        if not_permmited_payload = payload.detect { |key, value| !method_block[:options][:permit].include?(key) }  
          raise BadRequestError.new(message: "Not permitted payload: #{not_permmited_payload}") 
        end
      end
      params = {"payload" => payload}
      params["id"] = @id unless @id.nil?
      @result = @resource.execute(params, &method_block[:block])

      [status, @headers, [to_json]]
    end
  end

  class Resource 
    ACTION_METHODS = {create: 'POST', show: 'GET', update: 'PUT', destory: 'DELETE'}


    def initialize(block) 
      instance_eval(&block) 
    end

    def execute(params, &block)
      yield params
    end

    def model(object = nil, options = {})
      @model = object unless object.nil? 
      @model
    end

    def model_delegator
      @model_delegator ||= Model.new(model)
    end

    def actions; @actions ||= {} end
    def action(name, options = {}, &block)
      actions[ACTION_METHODS[name]] = {block: block, options: options}
    end

    def logger; Traim.logger  end 

    def resource(object = nil)
      @resource = object unless object.nil?
      @resource
    end

    def collections; @collections ||= {} end

    def collection(name, &block)
      collections[name] = block
    end
    
    def members; @members ||= {} end
    
    def member(name, &block)
      members[name] = block
    end

    def fields; @fields ||= [] end
    def attribute(name, &block)
      fields << {name: name, type: 'attribute', block: block} 
    end

    def has_many(name)
      fields << {name: name, type: 'association'}
    end

    def has_one(name)
      fields << {name: name, type: 'connection'}
    end

    def to_hash(object, resources, nest_associations = []) 
      return if object.nil?

      fields.inject({}) do | hash, attr|
        name = attr[:name]
        hash[name] = if attr[:type] == 'attribute'
          if attr[:block].nil?
            object.attributes[name.to_s]
          else
            execute(object, &attr[:block])
          end
        elsif  attr[:type] == 'association'
          raise Error if nest_associations.include?(name)
          raise Error if object.class.reflections[name.to_s].blank?
          nest_associations << name
          object.send(name).map do |association|
            resources[name].to_hash(association, nest_associations) 
          end
        else
          resource_name = name.to_s.pluralize.to_sym
          raise Error.new(message: "Inifinite Association") if nest_associations.include?(resource_name)
          raise Error if object.class.reflections[name.to_s].blank?
          nest_associations << resource_name 
          resources[resource_name].to_hash(object.send(name), nest_associations)
        end
        hash
      end
    end
  end

  class Model

    def initialize(model)
      @model = model 
    end

    def create(params)
      resource = @model.new(params)
      resource.save
      resource
    end

    def show(id)
      @model.find id
    end

    def delete(id)
      show(id).delete
    end

    def update(id, params)
      resource = show(id)
      resource.assign_attributes(params)
      resource.save
      resource 
    end
  end
end
