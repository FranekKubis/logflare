defmodule Logflare.ContextCache.CacheBusterTest do
  use Logflare.DataCase

  alias Cainophile.Changes.DeletedRecord
  alias Cainophile.Changes.NewRecord
  alias Cainophile.Changes.Transaction
  alias Cainophile.Changes.UpdatedRecord
  alias Logflare.ContextCache
  alias Logflare.ContextCache.CacheBuster
  alias Logflare.Sources

  setup do
    insert(:plan, name: "Free")
    user = insert(:user)
    source = insert(:source, user: user)
    [source: source, user: user]
  end

  test "cache buster", %{source: %{id: source_id, token: source_token}} do
    for child_spec <- ContextCache.Supervisor.buster_specs() do
      start_supervised!(child_spec)
    end

    Sources.Cache.get_by(token: source_token)
    assert Cachex.size!(Sources.Cache) == 1

    change = %DeletedRecord{
      relation: {"public", "sources"},
      old_record: %{"id" => Integer.to_string(source_id)}
    }

    test_pid = self()

    Mimic.expect(ContextCache, :bust_keys, fn arg ->
      Mimic.call_original(ContextCache, :bust_keys, [arg])
      send(test_pid, arg)
    end)

    send(CacheBuster, %Transaction{changes: [change]})
    assert_receive [{Sources, ^source_id}], 500
    assert Cachex.size!(Sources.Cache) == 0
  end

  test "emits WAL record and transaction lag events" do
    start_supervised!(CacheBuster)

    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:logflare, :cache_buster, :wal_record],
        [:logflare, :cache_buster, :transaction]
      ])

    changes = [
      %UpdatedRecord{relation: {"public", "sources"}, record: %{}, old_record: %{}},
      %NewRecord{relation: {"public", "rules"}, record: %{}}
    ]

    committed_at = DateTime.add(DateTime.utc_now(), -200, :millisecond)
    send(CacheBuster, %Transaction{changes: changes, commit_timestamp: committed_at})

    assert_receive {[:logflare, :cache_buster, :transaction], ^ref, %{lag: lag}, _}, 500
    assert lag >= 200

    assert_receive {[:logflare, :cache_buster, :wal_record], ^ref, %{count: 1},
                    %{table: "sources", operation: :update}}

    assert_receive {[:logflare, :cache_buster, :wal_record], ^ref, %{count: 1},
                    %{table: "rules", operation: :insert}}
  end
end
