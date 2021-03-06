require 'mailjet/resource'

module Mailjet
  class Newsletter_test
    include Mailjet::Resource
    self.action = "test"
    self.resource_path = "v3/REST/newsletter/id/#{self.action}"
    self.public_operations = [:post]
    self.filters = []
    self.properties = [:email, :name]

  end
end
