# frozen_string_literal: true
require "spec_helper"

describe GraphQL::Query::Result do
  let(:query_string) { '{ __type(name: "Cheese") { name } }' }
  let(:schema) { Dummy::Schema }
  let(:result) { schema.execute(query_string, context: { a: :b }) }

  it "exposes hash-like methods" do
    assert_equal "Cheese", result["data"]["__type"]["name"]
    refute result.key?("errors")
    assert_equal ["data"], result.keys
  end

  it "is equal with hashes" do
    hash_result = {"data" => { "__type" => { "name" => "Cheese" } } }
    assert_equal hash_result, result
  end

  it "tells the kind of operation" do
    assert result.query?
    refute result.mutation?
  end

  it "exposes the context" do
    assert_instance_of GraphQL::Query::Context, result.context
    if GraphQL::Schema.use_schema_visibility?
      assert_equal({a: :b, visibility_migration_running: true}, result.context.to_h)
    else
      assert_equal({a: :b}, result.context.to_h)
    end
  end
end
