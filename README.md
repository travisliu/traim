# Traim

Traim is a microframework for Building a RESTful API service from your existing ActiveRecord models.

## Getting started

### Installation
``` ruby
gem install train
```

### Usage
Here's a simple application:
``` ruby
# cat hello_traim.rb

Traim.config do |app|
  app.logger = Logger.new(STDOUT)
end

class User < ActiveRecord::Base
end

Train.application do
  resource :users do
    # Inject user model
    model User

    # Response json: {id: 1, name: “example"}
    attribute :id
    attribute :name

    # POST /users
    action :create

    # GET /users/:id
    action :show

    # PUT /users/:id
    action :update

    # DELETE /users/:id
    action :destory
  end
end
```
put your activerecord config in
` config/database.yml `

To run it, you can create a config.ru file
``` ruby
# cat config.ru
require 'hello_traim.rb'

run Traim
```

Then run `rackup`.

Now, you already get basic CURD RESTful API from the user ActiveRecord model.

## Customizable action
By default, `action` can be easily used to create an endpoint for CRUD operations. you can write your own endpoint as well.
``` ruby
Traim.application do
  resources :users do
    model User

    attribute :id
    attribute :name

    action :show do |params|
      user = model.find_by_email params["payload"]["email"]
      user.name = "[admin] #{user.name}"
      user
    end
  end
end
```

Response
``` json
{"id": 1, "name": "[admin] travis"}
```

## Associations
create nestea json reponse with activerecord association
``` ruby
class User < ActiveRecord::Base
  has_many :books
end

class Book < ActiveRecord::Base
  belongs_to :user
end

Traim.application do
  resources :users do
    model User

    attribute :id
    attribute :name

    action :show

    has_many: books
  end

  resources :books do
    model Book

    attribute :isbn
  end
end
```

Response
``` json
{
  "id": 1,
  "name": "travis"
  "books": [
    {"isbn": "978-1-61-729109-8"},
    {"isbn": "561-6-28-209847-7"},
    {"isbn": "527-3-83-394862-5"}
  ]
}
```

## Member
Member block can add actions to a specific record with id
``` Ruby
Traim.application do
  resources :users do
    model User

    attribute :id
    attribute :name

    member :blurred do

      # GET /users/1/blurred
      show do |params|
        record.name[1..2] = 'xx'
        record
      end
    end
  end
end
```

## Collection
Collection block can add actions to operate resources
``` Ruby
Traim.application do
  resources :users do
    model User

    attribute :id
    attribute :name

    collection :admin do

      # GET /users/admin
      show do |params|
        model.all
      end

      # POST /users/admin
      create do |params|
        model.create(params["payload"])
      end
    end
  end
end
```

## Namespaces
Organize groups of resources under a namespace. Most commonly, you might arrange resources for versioning.
``` ruby
Traim.application do
  namespace :api do
    namespace :v1 do
      resources :users do
        model User

        attribute :id
        attribute :name

        # endpoint: /api/v1/users
        action :show
      end
    end

    namespace :v2 do
      resources :users do
        model User

        attribute :id
        attribute :name

        # endpoint: /api/v2/users
        action :show
      end
    end
  end
end
```

## Helpers
You can define helper methods that your endpoints can use with the helpers to deal with some common flow controls, like authentication or authorization.
``` ruby
Traim.application do
  resources :users do
    helpers do
      def auth(user_id) 
        raise BadRequestError.new(message: "unauthenticated request") unless model.exists?(id: user_id)
      end
    end

    model User

    attribute :id
    attribute :name

    action :show do |params|
      auth(params["id"])
      model.find params["id"]
      user
    end
  end
end
```

## Visual attributes
Built-in attribute is generate response fields from model. Visual can help you present fields outside of model attributes. 
``` ruby
Traim.application do
  resources :users do
    model User

    attribute :id
    attribute :name

    attribute :vattr do |record|
      "#{record.id} : #{record.email}"
    end

    action :show
  end
end
```

Response
``` json
{"id": 1, "name": "travis", "vattr": "1 : travis"}
```

### Parameters whitelist
Built-in model operations are using mass assignment. For security concern, Parameters can be whitelisted with permit option.
``` ruby
Traim.application do
  resources :users do
    model User

    attribute :id
    attribute :name

    action :create, permit: ["name"]
  end
end
```
