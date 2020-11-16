#!/bin/env ruby
require 'kubeclient'
require 'yaml'

config = Kubeclient::Config.read(ENV['KUBECONFIG'])
context = config.context
puts config.context.api_endpoint

c = Kubeclient::Client.new(context.api_endpoint+'/apis/eirini.cloudfoundry.org/', 'v1',
  ssl_options: context.ssl_options,
  auth_options: context.auth_options)

y = Kubeclient::Resource.new(YAML.load_file("lrp.yaml"))
c.create_entity("LRP", "lrps", y)

