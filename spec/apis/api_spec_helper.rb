#
# Copyright (C) 2011 Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.
#

require File.expand_path(File.dirname(__FILE__) + '/../spec_helper')

require 'nokogiri'

RSpec::configure do |c|
  # rspec-rails 3 will no longer automatically infer an example group's spec type
  # from the file location. You can explicitly opt-in to the feature using this
  # config option.
  # To explicitly tag specs without using automatic inference, set the `:type`
  # metadata manually:
  #
  #     describe ThingsController, :type => :controller do
  #       # Equivalent to being in spec/controllers
  #     end
  c.infer_spec_type_from_file_location!
end

class HashWithDupCheck < Hash
  def []=(k,v)
    if self.key?(k)
      raise ArgumentError, "key already exists: #{k.inspect}"
    else
      super
    end
  end
end

# make an API call using the given method (GET/PUT/POST/DELETE),
# to the given path (e.g. /api/v1/courses). params will be verified to match the
# params generated by the Rails routing engine. body_params are params in a
# PUT/POST that are included in the body rather than the URI, and therefore
# don't affect routing.
def api_call(method, path, params, body_params = {}, headers = {}, opts = {})
  raw_api_call(method, path, params, body_params, headers, opts)
  if opts[:expected_status]
    assert_status(opts[:expected_status])
  else
    expect(response).to be_success, response.body
  end

  if response.headers['Link']
    # make sure that the link header is properly formed
    Api.parse_pagination_links(response.headers['Link'])
  end

  if jsonapi_call?(headers) && method == :delete
    assert_status(204)
    return
  end

  case params[:format]
  when 'json'
    expect(response.header[content_type_key]).to eq 'application/json; charset=utf-8'

    body = response.body
    if body.respond_to?(:call)
      StringIO.new.tap { |sio| body.call(nil, sio); body = sio.string }
    end
    body.sub!(%r{^while\(1\);}, '')
    # Check that the body doesn't have any duplicate keys. this can happen if
    # you add both a string and a symbol to the hash before calling to_json on
    # it.
    # The ruby JSON gem allows this, and it's technically valid JSON to have
    # duplicate names in an object ("names SHOULD be unique"), but it's silly
    # and we're not gonna let it slip through again.
    JSON.parse(body, :object_class => HashWithDupCheck)
  else
    raise("Don't know how to handle response format #{params[:format]}")
  end
end

def jsonapi_call?(headers)
  headers['Accept'] == 'application/vnd.api+json'
end

# like api_call, but performed by the specified user instead of @user
def api_call_as_user(user, method, path, params, body_params = {}, headers = {}, opts = {})
  token = access_token_for_user(user)
  headers['Authorization'] = "Bearer #{token}"
  account = opts[:domain_root_account] || Account.default
  user.pseudonyms.reload
  account.pseudonyms.create!(:unique_id => "#{user.id}@example.com", :user => user) unless user.find_pseudonym_for_account(account, true)
  Pseudonym.any_instance.stubs(:works_for_account?).returns(true)
  api_call(method, path, params, body_params, headers, opts)
end

$spec_api_tokens = {}

def access_token_for_user(user)
  token = $spec_api_tokens[user]
  unless token
    token = $spec_api_tokens[user] = user.access_tokens.create!(:purpose => "test").full_token
  end
  token
end

# like api_call, but don't assume success and a json response.
def raw_api_call(method, path, params, body_params = {}, headers = {}, opts = {})
  path = path.sub(%r{\Ahttps?://[^/]+}, '') # remove protocol+host
  enable_forgery_protection do
    params_from_with_nesting(method, path).each do |key, value|
      expect(params[key].to_s).to eq(value.to_s), lambda{ "Expected value of params[\'#{key}\'] to equal #{value}, actual: #{params[key]}"}
    end
    if @use_basic_auth
      user_session(@user)
    else
      headers['HTTP_AUTHORIZATION'] = headers['Authorization'] if headers.key?('Authorization')
      if !params.key?(:api_key) && !params.key?(:access_token) && !headers.key?('HTTP_AUTHORIZATION') && @user
        token = access_token_for_user(@user)
        headers['HTTP_AUTHORIZATION'] = "Bearer #{token}"
        account = opts[:domain_root_account] || Account.default
        Pseudonym.any_instance.stubs(:works_for_account?).returns(true)
        account.pseudonyms.create!(:unique_id => "#{@user.id}@example.com", :user => @user) unless @user.all_active_pseudonyms(:reload) && @user.find_pseudonym_for_account(account, true)
      end
    end
    LoadAccount.stubs(:default_domain_root_account).returns(opts[:domain_root_account]) if opts.has_key?(:domain_root_account)
    __send__(method, path, params.reject { |k,v| %w(controller action).include?(k.to_s) }.merge(body_params), headers)
  end
end

def follow_pagination_link(rel, params={})
  links = Api.parse_pagination_links(response.headers['Link'])
  link = links.find{ |l| l[:rel] == rel }
  link.delete(:rel)
  uri = link.delete(:uri).to_s
  link.each{ |key,value| params[key.to_sym] = value }
  api_call(:get, uri, params)
end

def params_from_with_nesting(method, path)
  path, querystring = path.split('?')
  params = CanvasRails::Application.routes.recognize_path(path, :method => method)
  querystring.blank? ? params : params.merge(Rack::Utils.parse_nested_query(querystring).symbolize_keys!)
end

def api_json_response(objects, opts = nil)
  JSON.parse(objects.to_json(opts.merge(:include_root => false)))
end

def check_document(html, course, attachment, include_verifiers)
  doc = Nokogiri::HTML::DocumentFragment.parse(html)
  img1 = doc.at_css('img#1')
  expect(img1).to be_present
  params = include_verifiers ? "?verifier=#{attachment.uuid}" : ""
  expect(img1['src']).to eq "http://www.example.com/courses/#{course.id}/files/#{attachment.id}/preview#{params}"
  img2 = doc.at_css('img#2')
  expect(img2).to be_present
  expect(img2['src']).to eq "http://www.example.com/courses/#{course.id}/files/#{attachment.id}/download#{params}"
  video = doc.at_css('video')
  expect(video).to be_present
  expect(video['poster']).to match(%r{http://www.example.com/media_objects/qwerty/thumbnail})
  expect(video['src']).to match(%r{http://www.example.com/courses/#{course.id}/media_download})
  expect(video['src']).to match(%r{entryId=qwerty})
  expect(doc.css('a').last['data-api-endpoint']).to match(%r{http://www.example.com/api/v1/courses/#{course.id}/pages/awesome-page})
  expect(doc.css('a').last['data-api-returntype']).to eq 'Page'
end

# passes the cb a piece of user content html text. the block should return the
# response from the api for that field, which will be verified for correctness.
def should_translate_user_content(course, include_verifiers=true)
  attachment = attachment_model(:context => course)
  content = %{
    <p>
      Hello, students.<br>
      This will explain everything: <img id="1" src="/courses/#{course.id}/files/#{attachment.id}/preview" alt="important">
      This won't explain anything:  <img id="2" src="/courses/#{course.id}/files/#{attachment.id}/download" alt="important">
      Also, watch this awesome video: <a href="/media_objects/qwerty" class="instructure_inline_media_comment video_comment" id="media_comment_qwerty"><img></a>
      And refer to this <a href="/courses/#{course.id}/pages/awesome-page">awesome wiki page</a>.
    </p>
  }
  html = yield content
  check_document(html, course, attachment, include_verifiers)

  if include_verifiers
    # try again but with cookie auth; shouldn't have verifiers now
    @use_basic_auth = true
    html = yield content
    check_document(html, course, attachment, false)
  end
end

def should_process_incoming_user_content(context)
  attachment_model(:context => context)
  incoming_content = "<p>content blahblahblah <a href=\"/files/#{@attachment.id}/download?a=1&amp;verifier=2&amp;b=3\">haha</a></p>"

  saved_content = yield incoming_content
  expect(saved_content).to eq "<p>content blahblahblah <a href=\"/#{context.class.to_s.underscore.pluralize}/#{context.id}/files/#{@attachment.id}/download?a=1&amp;b=3\">haha</a></p>"
end

def verify_json_error(error, field, code, message = nil)
  expect(error["field"]).to eq field
  expect(error["code"]).to eq code
  expect(error["message"]).to eq message if message
end


# Assert the provided JSON hash complies with the JSON-API format specification.
#
# The following tests will be carried out:
#
#   - all resource entries must be wrapped inside arrays, even if the set
#     includes only a single resource entry
#   - when associations are present, a "meta" entry should be present and
#     it should indicate the primary set in the "primaryCollection" key
#
# @param [Hash] json
#   The JSON construct to test.
#
# @param [String] primary_set
#   Name of the primary resource the construct represents, i.e, the model
#   the API endpoint represents, like 'quiz', 'assignment', or 'submission'.
#
# @param [Array<String>] associations
#   An optional set of associated resources that should be included with
#   the primary resource (e.g, a user, an assignment, a submission, etc.).
#
# @example Testing a Quiz API model:
#   test_jsonapi_compliance!(json, 'quiz')
#
# @example Testing a Quiz API model with its assignment included:
#   test_jsonapi_compliance!(json, 'quiz', [ 'assignment' ])
#
# @example A complying construct of a Quiz Submission with its Assignment:
#
#     {
#       "quiz_submissions": [{
#         "id": 10,
#         "assignment_id": 5
#       }],
#       "assignments": [{
#         "id": 5
#       }],
#       "meta": {
#         "primaryCollection": "quiz_submissions"
#       }
#     }
#
def assert_jsonapi_compliance(json, primary_set, associations = [])
  required_keys =  [ primary_set ]

  if associations.any?
    required_keys.concat associations.map { |s| s.pluralize }
    required_keys << 'meta'
  end

  # test key values instead of nr. of keys so we get meaningful failures
  expect(json.keys.sort).to eq required_keys.sort

  required_keys.each do |key|
    expect(json).to be_has_key(key)
    expect(json[key].is_a?(Array)).to be_truthy unless key == 'meta'
  end

  if associations.any?
    expect(json['meta']['primaryCollection']).to eq primary_set
  end
end
