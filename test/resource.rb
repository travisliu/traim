require "cutest"
require_relative "../lib/traim"

Traim.config do |app| 
  app.logger = Logger.new(STDOUT)
  app.logger.level = Logger::INFO
end

class User < ActiveRecord::Base 
  validates_presence_of :name

  has_many :books
end

class Book < ActiveRecord::Base 
  belongs_to :user
end


def mock_request(app, url, method, payload = nil)
  env = Rack::MockRequest.env_for( url,
    "REQUEST_METHOD" => method,
    :input => payload
  )
  
  app.call(env)
end

prepare do 
end

setup do
  User.create(name: "kolo", email: "kolo@gmail.com")
end

test "basic create, read, update and destory functionality" do |params|
  app = Traim.application do 
    resources :users do
      model User

      attribute :id
      attribute :name

      action :create
      action :show
      action :update
      action :destory
    end
  end
  
  _, _, response = mock_request(app, "/users", "POST", "name=kolo&email=kolo@gmail.com")
  user = JSON.parse(response.first)
  
  _, _, response = mock_request(app, "/users/#{user["id"]}", "GET")
  result = JSON.parse(response.first) 
  assert result["name"] == "kolo"

  _, _, response = mock_request(app, "/users/#{user["id"]}?name=ivan", "PUT")
  result = JSON.parse(response.first) 
  model = User.find(user["id"].to_i)
  assert model.name == "ivan"
  
  _, _, response = mock_request(app, "/users/#{user["id"]}?name=ivan", "DELETE")
  result = JSON.parse(response.first) 
  assert !User.exists?(user["id"])
end

test "customize functionality" do |user|
  app = Traim.application do 
    resources :users do
      model User

      attribute :id
      attribute :name

      action :show do 
        record.name = "[admin] #{record.name}"
        record 
      end
    end
  end
  
  _, _, response = mock_request(app, "/users/#{user.id}", "GET")
  result = JSON.parse(response.first) 
  assert result["name"] == "[admin] kolo"
end

test "member create, read, update and destory functionality" do |user|
  app = Traim.application do 
    resources :users do
      model User

      attribute :id
      attribute :name

      member :blurred do 
        show do 
          record.name[1..2] = "xx" 
          record 
        end

        update do 
          record.assign_attributes(params)
          record.save
          record 
        end

       destory do 
          record.delete
        end
      end 
    end
  end
 
  _, _, response = mock_request(app, "/users/#{user.id}/blurred", "GET")
  result = JSON.parse(response.first) 
  assert result["name"] == "kxxo"

  _, _, response = mock_request(app, "/users/#{user.id}/blurred?name=ivan", "PUT")
  assert User.find(user.id).name == "ivan"

  _, _, response = mock_request(app, "/users/#{user.id}/blurred", "DELETE")
  assert !User.exists?(user.id)

end

test "collection create, read, update and destory functionality" do |user|
  User.create(name: 'Keven', email: 'keven@gmail.com')
  User.create(name: 'Ivan', email: 'ivan@gmail.com')

  app = Traim.application do 
    resources :users do
      model User

      attribute :id
      attribute :name

      collection :admin do
        show do 
          model.all
        end

        create do 
          model.create(params)
        end
      end
    end
  end

  _, _, response = mock_request(app, "/users/admin?a=123", "GET")
  result = JSON.parse(response.first) 
  assert result.size == User.all.size 

  _, _, response = mock_request(app, "/users/admin", "POST", "name=carol&email=shesee@gmail.com")
  result = JSON.parse(response.first) 
  assert result["name"] == "carol" 
end

test "error message" do |user|
  app = Traim.application do 
    resources :users do
      model User

      attribute :id
      attribute :name

      action :create
      action :show
      action :update
      action :destory
    end
  end

  _, _, response = mock_request(app, "/users", "POST", "email=kolo@gmail.com")
  result = JSON.parse(response.first)
  assert result["name"].first == "can't be blank"
end

test "has many functionality" do |user|
  book = Book.create(user: user, isbn: 'abc')

  app = Traim.application do 
    resources :users do
      model User

      attribute :id
      attribute :name

      has_many :books

      action :show

      collection :admin do
        show do 
          model.all
        end

        create do 
          # what to response?   
          model.create_record(params)
        end
      end
    end
    resources :books do
      model Book 

      attribute :isbn
    end
  end

  _, _, response = mock_request(app, "/users/#{user.id}", "GET")
  result = JSON.parse(response.first) 
  assert result["books"].size == user.books.size
end

test "has one functionality" do |user|
  book = Book.create(user: user, isbn: 'abc')

  app = Traim.application do 
    resources :books do
      model Book 
      attribute :isbn
     
      action :show

      has_one :user
    end

    resources :users do
      model User

      attribute :name
    end
  end

  _, _, response = mock_request(app, "/books/#{book.id}", "GET")
  result = JSON.parse(response.first) 
  assert result["user"]["name"] == user.name
end

test "namespace functionality" do |user|
  book = Book.create(user: user, isbn: 'abc')

  app = Traim.application do 
    namespace :api do
      namespace :v1 do
        resources :books do
          model Book 
          attribute :isbn

          has_one :user

          action :show
        end

        resources :users do
          model User

          attribute :name
        end
      end
    end
  end

  _, _, response = mock_request(app, "/api/v1/books/#{book.id}", "GET")
  result = JSON.parse(response.first) 
  assert result["user"]["name"] == user.name
end

test "virtual attributes functionality" do |user|
  app = Traim.application do 
    resources :users do
      model User

      attribute :id
      attribute :name

      attribute :vattr do |record|
        record.email + " : " + record.id.to_s
      end

      action :show
    end
  end
  
  _, _, response = mock_request(app, "/users/#{user.id}", "GET")
  result = JSON.parse(response.first) 
  assert result["name"] == "kolo"
end

test "attributes in action" do |user|
  book = Book.create(user: user, isbn: 'abc')
  app = Traim.application do 
    resources :users do
      model User

      attribute :id

      action :show do 
        attribute :name
        record
      end

      member :books do
        show do
          has_many :books

          record
        end
      end
    end

    resources :books do
      model Book 
      attribute :isbn

      has_one :user

      action :show
    end
  end
  
  _, _, response = mock_request(app, "/users/#{user.id}", "GET")
  result = JSON.parse(response.first) 
  assert result["name"] == "kolo"

  _, _, response = mock_request(app, "/users/#{user.id}/books", "GET")
  result = JSON.parse(response.first) 
  assert result["books"].first["isbn"] == book.isbn
end

test "strong parameters  functionality" do |user|
  app = Traim.application do 
    resources :users do
      model User

      attribute :id
      attribute :name

      action :create, permit: ["name"]
    end
  end
  
  _, _, response = mock_request(app, "/users", "POST", "name=kolo&email=kolo@gmail.com")
  result = JSON.parse(response.first) 
  assert result["message"] == "Bad Request Error"
end

test "helpers functionality" do |user|
  app = Traim.application do 
    helpers do 
      def auth(params = nil)
        logger.debug "auth: #{params}, all: #{model.all}"
      end
    end

    resources :users do
      model User

      attribute :id
      attribute :name

      member :blurred do 
        show do
          helper.auth('test')
          record.name[1..2] = "xx" 
          record 
        end

        update do
          record.assign_attributes(params)
          record.save
          record 
        end

       destory do
          record.delete
        end
      end 
    end
  end
 
  _, _, response = mock_request(app, "/users/#{user.id}/blurred", "GET")
  result = JSON.parse(response.first) 
  assert result["name"] == "kxxo"

  _, _, response = mock_request(app, "/users/#{user.id}/blurred?name=ivan", "PUT")
  assert User.find(user.id).name == "ivan"

  _, _, response = mock_request(app, "/users/#{user.id}/blurred", "DELETE")
  assert !User.exists?(user.id)

end

test "headers functionality" do |user|
  app = Traim.application do 
    resources :users do
      model User

      attribute :id
      attribute :name

      member :headers do 
        show do 
          headers("test", "yeah")
          record 
        end
      end 
    end
  end
 
  _, headers, response = mock_request(app, "/users/#{user.id}/headers", "GET")
  assert headers["test"] == "yeah"
end


Book.delete_all
User.delete_all
