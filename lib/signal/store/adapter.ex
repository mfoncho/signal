defmodule Signal.Store.Adapter do

    def application_store(application) when is_atom(application) do
        Kernel.apply(application, :store, [])
    end

    def get_effect(application, uuid, opts\\[]) do
        store = application_store(application)
        Kernel.apply(store, :get_effect, [uuid, opts])
    end

    def save_effect(application, effect, opts\\[]) do
        store = application_store(application)
        Kernel.apply(store, :save_effect, [effect, opts])
    end

    def list_effects(application, namespace, opts\\[]) do
        store = application_store(application)
        Kernel.apply(store, :list_effects, [namespace, opts])
    end

    def delete_effect(application, uuid, opts\\[]) do
        store = application_store(application)
        Kernel.apply(store, :delete_effect, [uuid, opts])
    end

    def commit_transaction(application, transaction, opts\\[]) do
        store = application_store(application)
        Kernel.apply(store, :commit_transaction, [transaction, opts])
    end

    def get_cursor(application, opts\\[]) do
        store = application_store(application)
        Kernel.apply(store, :get_cursor, [opts])
    end

    def get_event(application, number, opts\\[]) do 
        opts = Keyword.merge(opts, [range: [number, number]])
        case list_events(application, opts) do
            [head| _] ->
                head

            [] ->
                nil

            unknown -> 
                # Should not reach here!
                unknown
        end
    end

    def get_stream_event(application, stream_id, version, opts\\[]) do
        opts = Keyword.merge(opts, [range: [version, version]])
        case list_stream_events(application, stream_id, opts) do
            [head| _] ->
                head

            [] ->
                nil

            unknown -> 
                # Should not reach here!
                unknown
        end
    end

    def read_events(application, callback, opts\\[]) do
        store = application_store(application)
        Kernel.apply(store, :read_events, [callback, opts])
    end

    def read_stream_events(application, stream_id, callback, opts\\[]) do
        store = application_store(application)
        Kernel.apply(store, :read_stream_events, [stream_id, callback, opts])
    end

    def list_events(application, opts\\[]) do
        store = application_store(application)
        Kernel.apply(store, :list_events, [opts])
    end

    def list_stream_events(application, stream_id, opts\\[]) do
        store = application_store(application)
        Kernel.apply(store, :list_stream_events, [stream_id, opts])
    end

    def handler_position(application, handle, opts\\[]) do
        store = application_store(application)
        Kernel.apply(store, :handler_position, [handle, opts])
    end

    def handler_acknowledge(application, handle, number, opts\\[]) do
        store = application_store(application)
        Kernel.apply(store, :handler_acknowledge, [handle, number, opts])
    end

    def get_snapshot(application, id, opts\\[]) do
        store = application_store(application)
        Kernel.apply(store, :get_snapshot, [id, opts])
    end

    def delete_snapshot(application, id, opts\\[]) do
        store = application_store(application)
        Kernel.apply(store, :delete_snapshot, [id, opts])
    end

    def record_snapshot(application, snapshot, opts\\[]) do
        store = application_store(application)
        Kernel.apply(store, :record_snapshot, [snapshot, opts])
    end

    def stream_position(application, stream, opts\\[]) do
        store = application_store(application)
        Kernel.apply(store, :stream_position, [stream, opts])
    end

end

