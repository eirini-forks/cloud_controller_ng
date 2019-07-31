require 'spec_helper'
require 'actions/update_route_destinations'

module VCAP::CloudController
  RSpec.describe UpdateRouteDestinations do
    subject(:update_destinations) { UpdateRouteDestinations }
    let(:space) { Space.make }
    let(:app_model) { AppModel.make(guid: 'some-guid', space: space) }
    let(:app_model2) { AppModel.make(guid: 'some-other-guid', space: space) }
    let(:docker_app) { AppModel.make(:docker, guid: 'docker-app-guid', space: space) }
    let(:route) { Route.make }
    let!(:existing_destination) do
      VCAP::CloudController::RouteMappingModel.make(
        app: app_model,
        route: route,
        process_type: 'existing',
        app_port: 3001,
      )
    end
    let!(:process1) { ProcessModel.make(:process, guid: 'process1-guid', app: app_model, type: 'web', health_check_type: 'none') }
    let!(:process2) { ProcessModel.make(:process, guid: 'process2-guid', app: app_model2, type: 'worker', health_check_type: 'none') }
    let!(:process3) { ProcessModel.make(:process, guid: 'process3-guid', app: app_model, type: 'existing', health_check_type: 'none', ports: [3001]) }
    let!(:docker_process) { ProcessModel.make(:process, app: docker_app, type: 'web') }
    let(:process1_route_handler) { instance_double(ProcessRouteHandler, update_route_information: nil) }
    let(:process2_route_handler) { instance_double(ProcessRouteHandler, update_route_information: nil) }
    let(:process3_route_handler) { instance_double(ProcessRouteHandler, update_route_information: nil) }
    let(:user_audit_info) { UserAuditInfo.new(user_email: 'user@example.com', user_guid: 'user-guid') }
    let(:app_event_repo) { instance_double(Repositories::AppEventRepository) }
    let(:apps_hash) do
      {
        app_model.guid => app_model,
        app_model2.guid => app_model2,
        docker_app.guid => docker_app
      }
    end

    describe '#add' do
      context 'when all destinations are valid' do
        let(:params) do
          [
            {
              app_guid: app_model.guid,
              process_type: 'web',
              app_port: 7000,
              weight: nil,
            },
            {
              app_guid: app_model2.guid,
              process_type: 'worker',
              app_port: ProcessModel::NO_APP_PORT_SPECIFIED,
              weight: nil,
            },
          ]
        end

        before do
          allow(ProcessRouteHandler).to receive(:new).with(process1).and_return(process1_route_handler)
          allow(ProcessRouteHandler).to receive(:new).with(process2).and_return(process2_route_handler)
        end

        it 'adds all the destinations and updates the routing' do
          expect {
            subject.add(params, route, apps_hash, user_audit_info)
          }.to change { RouteMappingModel.count }.by(2)
          route.reload
          mappings = route.route_mappings.collect do |rm|
            { app_guid: rm.app_guid, process_type: rm.process_type, app_port: rm.app_port }
          end
          expect(mappings).to contain_exactly(
            { app_guid: app_model.guid, process_type: 'web', app_port: 7000 },
            { app_guid: app_model.guid, process_type: 'existing', app_port: 3001 },
            { app_guid: app_model2.guid, process_type: 'worker', app_port: ProcessModel::NO_APP_PORT_SPECIFIED },
          )
        end

        it 'delegates to the route handler to update route information' do
          subject.add(params, route, apps_hash, user_audit_info)

          expect(process1_route_handler).to have_received(:update_route_information).with(
            perform_validation: false,
            updated_ports: [7000]
          )

          expect(process2_route_handler).to have_received(:update_route_information).with(
            perform_validation: false,
            updated_ports: nil
          )
        end

        context 'when there are weighted routes in the database' do
          before do
            existing_destination.update(weight: 10)
          end

          it 'rejects any inserts' do
            expect {
              subject.add(params, route, apps_hash, user_audit_info)
            }.to raise_error(
              UpdateRouteDestinations::Error,
              'Destinations cannot be inserted when there are weighted destinations already configured.'
            ).and change { RouteMappingModel.count }.by(0)
          end
        end

        describe 'audit events' do
          context 'not from manifest' do
            before do
              allow(Repositories::AppEventRepository).to receive(:new).and_return(app_event_repo)
              allow(app_event_repo).to receive(:record_map_route)
              subject.add(params, route, apps_hash, user_audit_info)
            end

            it 'records an audit event for each new route mapping' do
              route.reload
              route.route_mappings.reject { |rm| rm.process_type == 'existing' }.each do |rm|
                expect(app_event_repo).to have_received(:record_map_route).once.with(user_audit_info, rm, manifest_triggered: false)
              end
            end
          end

          context 'from manifest' do
            before do
              allow(Repositories::AppEventRepository).to receive(:new).and_return(app_event_repo)
              allow(app_event_repo).to receive(:record_map_route)
              subject.add(params, route, apps_hash, user_audit_info, manifest_triggered: true)
            end

            it 'records an audit event when triggered by a manifest' do
              route.reload
              route.route_mappings.reject { |rm| rm.process_type == 'existing' }.each do |rm|
                expect(app_event_repo).to have_received(:record_map_route).once.with(user_audit_info, rm, manifest_triggered: true)
              end
            end
          end
        end

        describe 'copilot integration' do
          before do
            allow(Copilot::Adapter).to receive(:map_route)
          end

          it 'delegates to the copilot handler to notify copilot' do
            expect {
              subject.add(params, route, apps_hash, user_audit_info)
              expect(Copilot::Adapter).to have_received(:map_route).with(have_attributes(process_type: 'web'))
              expect(Copilot::Adapter).to have_received(:map_route).with(have_attributes(process_type: 'worker'))
              expect(Copilot::Adapter).not_to have_received(:map_route).with(have_attributes(process_type: 'existing'))
            }.to change { RouteMappingModel.count }.by(2)
          end
        end
      end

      context 'when a fully equal destination already exists' do
        context 'destination includes buildpack app' do
          let!(:same_destination) do
            RouteMappingModel.make(
              app: app_model,
              route: route,
              app_port: 8080,
              process_type: 'web'
            )
          end

          let(:params) do
            [
              {
                app_guid: app_model.guid,
                process_type: 'web',
                app_port: nil,
                weight: nil,
              },
            ]
          end

          it "doesn't add the new destination" do
            expect {
              subject.add(params, route, apps_hash, user_audit_info)
            }.to change { RouteMappingModel.count }.by(0)
          end

          describe 'audit events' do
            before do
              allow(Repositories::AppEventRepository).to receive(:new).and_return(app_event_repo)
              allow(app_event_repo).to receive(:record_map_route)
              subject.add(params, route, apps_hash, user_audit_info)
            end

            it 'does not record an audit event for an existing route mapping' do
              expect(app_event_repo).not_to have_received(:record_map_route)
            end
          end
        end

        context 'destination includes docker app' do
          let!(:same_destination) do
            RouteMappingModel.make(
              app: docker_app,
              route: route,
              app_port: ProcessModel::NO_APP_PORT_SPECIFIED,
              process_type: 'web'
            )
          end

          let(:params) do
            [
              {
                app_guid: docker_app.guid,
                process_type: 'web',
                app_port: nil,
                weight: nil,
              },
            ]
          end

          it "doesn't add the new destination" do
            expect {
              subject.add(params, route, apps_hash, user_audit_info)
            }.to change { RouteMappingModel.count }.by(0)
          end

          describe 'audit events' do
            before do
              allow(Repositories::AppEventRepository).to receive(:new).and_return(app_event_repo)
              allow(app_event_repo).to receive(:record_map_route)
              subject.add(params, route, apps_hash, user_audit_info)
            end

            it 'does not record an audit event for an existing route mapping' do
              expect(app_event_repo).not_to have_received(:record_map_route)
            end
          end
        end
      end

      context 'when the destination process does not have any ports open' do
        let(:params) do
          [
            {
              app_guid: docker_app.guid,
              process_type: docker_process.type,
              app_port: ProcessModel::NO_APP_PORT_SPECIFIED,
              weight: nil,
            },
          ]
        end

        it 'adds all the destinations and updates the routing' do
          expect {
            subject.add(params, route, apps_hash, user_audit_info)
          }.to change { RouteMappingModel.count }.by(1)
          route.reload
          mappings = route.route_mappings.collect do |rm|
            { app_guid: rm.app_guid, process_type: rm.process_type, app_port: rm.app_port }
          end
          expect(mappings).to contain_exactly(
            { app_guid: app_model.guid, process_type: 'existing', app_port: 3001 },
            { app_guid: docker_app.guid, process_type: 'web', app_port: -1 },
          )
        end

        it 'leaves the destination process ports nil' do
          subject.add(params, route, apps_hash, user_audit_info)

          docker_process.reload
          expect(docker_process.ports).to be_nil
        end
      end

      context 'when a destination has invalid ports' do
        let(:params) do
          [
            {
              app_guid: app_model.guid,
              process_type: 'web',
              app_port: -2000000,
              weight: nil,
            },
          ]
        end

        it "doesn't add the new destination" do
          expect {
            subject.add(params, route, apps_hash, user_audit_info)
          }.to raise_error(UpdateRouteDestinations::Error, /Ports must be in the 1024-65535/)
        end
      end
    end

    describe '#replace' do
      context 'when all destinations are valid' do
        let(:params) do
          [
            {
              app_guid: app_model.guid,
              process_type: 'web',
              app_port: 7000,
              weight: nil,
            },
            {
              app_guid: app_model2.guid,
              process_type: 'worker',
              app_port: 8081,
              weight: nil,
            },
          ]
        end

        before do
          allow(ProcessRouteHandler).to receive(:new).with(process1).and_return(process1_route_handler)
          allow(ProcessRouteHandler).to receive(:new).with(process2).and_return(process2_route_handler)
          allow(ProcessRouteHandler).to receive(:new).with(process3).and_return(process3_route_handler)
        end

        it 'replaces all the route_mappings' do
          expect {
            subject.replace(params, route, apps_hash, user_audit_info)
          }.to change { RouteMappingModel.count }.by(1)
          route.reload
          mappings = route.route_mappings.collect do |rm|
            { app_guid: rm.app_guid, process_type: rm.process_type, app_port: rm.app_port }
          end
          expect(mappings).to contain_exactly(
            { app_guid: app_model.guid, process_type: 'web', app_port: 7000 },
            { app_guid: app_model2.guid, process_type: 'worker', app_port: 8081 },
          )
        end

        it 'delegates to the route handler to update route information' do
          subject.replace(params, route, apps_hash, user_audit_info)

          expect(process1_route_handler).to have_received(:update_route_information).with(
            perform_validation: false,
            updated_ports: [7000]
          )
          expect(process2_route_handler).to have_received(:update_route_information).with(
            perform_validation: false,
            updated_ports: [8081]
          )
          expect(process3_route_handler).to have_received(:update_route_information).with(
            perform_validation: false,
            updated_ports: nil
          )
        end

        describe 'audit events' do
          context 'not from manifest' do
            before do
              allow(Repositories::AppEventRepository).to receive(:new).and_return(app_event_repo)
              allow(app_event_repo).to receive(:record_map_route)
              allow(app_event_repo).to receive(:record_unmap_route)
              subject.replace(params, route, apps_hash, user_audit_info)
            end

            it 'records an audit event for each new route mapping' do
              route.reload
              route.route_mappings.each do |rm|
                expect(app_event_repo).to have_received(:record_map_route).once.with(user_audit_info, rm, manifest_triggered: false)
              end
            end
            it 'records an audit event for each new route unmapping' do
              expect(app_event_repo).to have_received(:record_unmap_route).once.with(user_audit_info, existing_destination, manifest_triggered: false)
            end
          end

          context 'from manifest' do
            before do
              allow(Repositories::AppEventRepository).to receive(:new).and_return(app_event_repo)
              allow(app_event_repo).to receive(:record_map_route)
              allow(app_event_repo).to receive(:record_unmap_route)
              subject.replace(params, route, apps_hash, user_audit_info, manifest_triggered: true)
            end

            it 'records an audit event for each new route mapping' do
              route.reload
              route.route_mappings.each do |rm|
                expect(app_event_repo).to have_received(:record_map_route).once.with(user_audit_info, rm, manifest_triggered: true)
              end
            end
            it 'records an audit event for each new route unmapping' do
              expect(app_event_repo).to have_received(:record_unmap_route).once.with(user_audit_info, existing_destination, manifest_triggered: true)
            end
          end
        end

        describe 'copilot integration' do
          before do
            allow(Copilot::Adapter).to receive(:map_route)
            allow(Copilot::Adapter).to receive(:unmap_route)
          end

          it 'delegates to the copilot handler to notify copilot' do
            expect {
              subject.replace(params, route, apps_hash, user_audit_info)
              expect(Copilot::Adapter).to have_received(:map_route).with(have_attributes(process_type: 'web'))
              expect(Copilot::Adapter).to have_received(:map_route).with(have_attributes(process_type: 'worker'))
              expect(Copilot::Adapter).to have_received(:unmap_route).with(have_attributes(process_type: 'existing'))
            }.to change { RouteMappingModel.count }.by(1)
          end
        end
      end

      context 'when a fully equal destination already exists' do
        let!(:same_destination) do
          RouteMappingModel.make(
            app: app_model,
            route: route,
            app_port: ProcessModel::DEFAULT_HTTP_PORT,
            process_type: 'web'
          )
        end

        let(:params) do
          [
            {
              app_guid: app_model.guid,
              process_type: 'web',
              app_port: ProcessModel::DEFAULT_HTTP_PORT,
              weight: nil,
            },
          ]
        end

        it 'removes the non-matching destination and preserves the matching destination' do
          expect {
            subject.replace(params, route, apps_hash, user_audit_info)
          }.to change { RouteMappingModel.count }.by(-1)
        end

        describe 'audit events' do
          before do
            allow(Repositories::AppEventRepository).to receive(:new).and_return(app_event_repo)
            allow(app_event_repo).to receive(:record_map_route)
            allow(app_event_repo).to receive(:record_unmap_route)
            subject.replace(params, route, apps_hash, user_audit_info)
          end

          it 'does not record an audit event for a new route mapping' do
            expect(app_event_repo).not_to have_received(:record_map_route)
            expect(app_event_repo).to have_received(:record_unmap_route).once.with(user_audit_info, existing_destination, manifest_triggered: false)
          end
        end
      end
    end

    describe '#delete' do
      it 'deletes the route mapping record' do
        expect {
          subject.delete(existing_destination, route, user_audit_info)
        }.to change { RouteMappingModel.count }.by(-1)
        expect { existing_destination.refresh }.to raise_error Sequel::Error, 'Record not found'
      end

      context 'when there are weighted routes in the database' do
        before do
          existing_destination.update(weight: 10)
        end

        it 'rejects the delete' do
          expect {
            subject.delete(existing_destination, route, user_audit_info)
          }.to raise_error(
            UpdateRouteDestinations::Error,
            'Weighted destinations cannot be deleted individually.'
          ).and change { RouteMappingModel.count }.by(0)
        end
      end

      context 'when there are multiple routes with destinations to the same process' do
        let(:other_route) { Route.make }

        let!(:other_existing_destination) do
          VCAP::CloudController::RouteMappingModel.make(
            app: app_model,
            route: other_route,
            process_type: 'existing',
            app_port: 3001,
          )
        end

        before do
          allow(ProcessRouteHandler).to receive(:new).with(process3).and_return(process3_route_handler)
        end

        it 'should not remove the process ports because they are still needed for the other destination' do
          subject.delete(existing_destination, route, user_audit_info)

          expect(process3_route_handler).to have_received(:update_route_information).with(
            perform_validation: false,
            updated_ports: [3001]
          )
        end
      end

      describe 'copilot integration' do
        before do
          allow(Copilot::Adapter).to receive(:unmap_route)
        end

        it 'delegates to the copilot handler to notify copilot' do
          subject.delete(existing_destination, route, user_audit_info)
          expect(Copilot::Adapter).to have_received(:unmap_route).with(existing_destination)
        end
      end

      describe 'diego integration' do
        let(:fake_process_route_handler) { instance_double(ProcessRouteHandler) }

        before do
          allow(ProcessRouteHandler).to receive(:new).with(process3).and_return(fake_process_route_handler)
          allow(fake_process_route_handler).to receive(:update_route_information)
        end

        it 'updates route information for route processes' do
          subject.delete(existing_destination, route, user_audit_info)

          expect(fake_process_route_handler).to have_received(:update_route_information).with(
            perform_validation: false,
            updated_ports: nil
          )
        end
      end

      describe 'audit events' do
        before do
          allow(Repositories::AppEventRepository).to receive(:new).and_return(app_event_repo)
          allow(app_event_repo).to receive(:record_unmap_route)
          subject.delete(existing_destination, route, user_audit_info)
        end

        it 'records an audit event for each new route mapping' do
          expect(app_event_repo).to have_received(:record_unmap_route).once.with(user_audit_info, existing_destination, manifest_triggered: false)
        end
      end
    end
  end
end