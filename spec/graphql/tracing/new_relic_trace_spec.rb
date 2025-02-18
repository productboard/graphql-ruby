# frozen_string_literal: true
require "spec_helper"

describe GraphQL::Tracing::NewRelicTrace do
  module NewRelicTraceTest
    class NestedSource < GraphQL::Dataloader::Source
      def fetch(keys)
        keys
      end
    end

    class OtherSource < GraphQL::Dataloader::Source
      def fetch(keys)
        dataloader.with(NestedSource).load_all(keys)
      end
    end
    class Thing < GraphQL::Schema::Object
      implements GraphQL::Types::Relay::Node
    end

    class Other < GraphQL::Schema::Object
      field :name, String, fallback_value: "other"
    end
    class Query < GraphQL::Schema::Object
      include GraphQL::Types::Relay::HasNodeField

      field :int, Integer, null: false

      def int
        1
      end

      field :other, Other

      def other
        dataloader.with(OtherSource).load(:other)
      end
    end

    class SchemaWithoutTransactionName < GraphQL::Schema
      query(Query)
      trace_with(GraphQL::Tracing::NewRelicTrace)
      orphan_types(Thing)

      def self.object_from_id(_id, _ctx)
        :thing
      end

      def self.resolve_type(_type, _obj, _ctx)
        Thing
      end
    end

    class SchemaWithTransactionName < GraphQL::Schema
      query(Query)
      trace_with(GraphQL::Tracing::NewRelicTrace, set_transaction_name: true)
      use GraphQL::Dataloader
    end

    class SchemaWithScalarTrace < GraphQL::Schema
      query(Query)
      trace_with(GraphQL::Tracing::NewRelicTrace, trace_scalars: true)
    end
  end

  before do
    NewRelic.clear_all
  end

  it "works with the built-in node field, even though it doesn't have an @owner" do
    res = NewRelicTraceTest::SchemaWithoutTransactionName.execute '{ node(id: "1") { __typename } }'
    assert_equal "Thing", res["data"]["node"]["__typename"]
  end

  it "can leave the transaction name in place" do
    NewRelicTraceTest::SchemaWithoutTransactionName.execute "query X { int }"
    assert_equal [], NewRelic::TRANSACTION_NAMES
  end

  it "can override the transaction name" do
    NewRelicTraceTest::SchemaWithTransactionName.execute "query X { int }"
    assert_equal ["GraphQL/query.X"], NewRelic::TRANSACTION_NAMES
  end

  it "can override the transaction name per query" do
    # Override with `false`
    NewRelicTraceTest::SchemaWithTransactionName.execute "{ int }", context: { set_new_relic_transaction_name: false }
    assert_equal [], NewRelic::TRANSACTION_NAMES
    # Override with `true`
    NewRelicTraceTest::SchemaWithoutTransactionName.execute "{ int }", context: { set_new_relic_transaction_name: true }
    assert_equal ["GraphQL/query.anonymous"], NewRelic::TRANSACTION_NAMES
  end

  it "falls back to a :tracing_fallback_transaction_name when provided" do
    NewRelicTraceTest::SchemaWithTransactionName.execute("{ int }", context: { tracing_fallback_transaction_name: "Abcd" })
    assert_equal ["GraphQL/query.Abcd"], NewRelic::TRANSACTION_NAMES
  end

  it "does not use the :tracing_fallback_transaction_name if an operation name is present" do
    NewRelicTraceTest::SchemaWithTransactionName.execute(
      "query Ab { int }",
      context: { tracing_fallback_transaction_name: "Cd" }
    )
    assert_equal ["GraphQL/query.Ab"], NewRelic::TRANSACTION_NAMES
  end

  it "does not require a :tracing_fallback_transaction_name even if an operation name is not present" do
    NewRelicTraceTest::SchemaWithTransactionName.execute("{ int }")
    assert_equal ["GraphQL/query.anonymous"], NewRelic::TRANSACTION_NAMES
  end

  it "traces scalars when trace_scalars is true" do
    NewRelicTraceTest::SchemaWithScalarTrace.execute "query X { int }"
    assert_includes NewRelic::EXECUTION_SCOPES, "GraphQL/Query/int"
  end

  it "handles fiber pauses" do
    NewRelicTraceTest::SchemaWithTransactionName.execute("{ other { name } }")
    expected_steps = [
      "GraphQL/parse",
      "FINISH GraphQL/parse",
      "GraphQL/execute",

        "GraphQL/analyze",
          "GraphQL/validate",
          "FINISH GraphQL/validate",
        "FINISH GraphQL/analyze",

        "GraphQL/Authorized/Query",
        "FINISH GraphQL/Authorized/Query",
        "GraphQL/Query/other",
        "FINISH GraphQL/Query/other",
        # Here's the source run:
        "GraphQL/Source/NewRelicTraceTest::OtherSource",
        "FINISH GraphQL/Source/NewRelicTraceTest::OtherSource",
          # Nested source:
          "GraphQL/Source/NewRelicTraceTest::NestedSource",
          "FINISH GraphQL/Source/NewRelicTraceTest::NestedSource",
        "GraphQL/Source/NewRelicTraceTest::OtherSource",
        "FINISH GraphQL/Source/NewRelicTraceTest::OtherSource",
        # And back to the field:
        "GraphQL/Query/other",
        "FINISH GraphQL/Query/other",
        "GraphQL/Authorized/Other",
        "FINISH GraphQL/Authorized/Other",
        "GraphQL/Other/name",
        "FINISH GraphQL/Other/name",
      "FINISH GraphQL/execute"
    ]
    assert_equal expected_steps, NewRelic::EXECUTION_SCOPES
  end
end
