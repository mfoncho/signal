defmodule Signal.Process.Router do

    @router_namespace "$router"

    use GenServer
    alias Signal.Event
    alias Signal.Effect
    alias Signal.Event.Broker
    alias Signal.Process.Saga
    alias Signal.Process.Router
    alias Signal.Process.Supervisor

    defstruct [
        :app, 
        :uuid,
        :name, 
        :topics, 
        :module, 
        :timeout, 
        :consumer, 
        :instances,
        :processing,
    ]

    defmodule Instance do
        alias Signal.Effect
        alias Signal.Process.Router
        alias Signal.Process.Supervisor

        defstruct [
            :id, 
            :app,
            :uuid, 
            :pid, 
            :ack, 
            :syn, 
            :ref, 
            :namespace, 
            status: :sleeping, 
            queue: []
        ]

        def new(opts) do
            id = Keyword.fetch!(opts, :id)
            pid = Keyword.get(opts, :pid)
            ack = Keyword.get(opts, :ack, 0)
            namespace = Keyword.fetch!(opts, :namespace)
            uuid = Effect.uuid(namespace, id)
            {ref, pid} = 
                cond do
                    is_pid(pid) ->
                        {Process.monitor(pid), pid}

                    is_nil(pid) ->
                        {nil, nil}

                    true ->
                        {nil, nil}
                end

            opts = 
                opts
                |> Keyword.merge([ack: ack])
                |> Keyword.merge([syn: ack])
                |> Keyword.merge([ref: ref])
                |> Keyword.merge([pid: pid])
                |> Keyword.merge([uuid: uuid])

            struct(__MODULE__, opts) 
        end

        def mark_as_running(%Instance{}=instances) do
            %Instance{instances| status: :running}
        end

        def push_event(%Instance{}=instance, {action, %Event{number: number}=event}) do

            %Instance{pid: pid, syn: syn, ack: ack, queue: queue} = instance

            {naction, nevent} = List.first(queue, {action, event})

            queue = 
                cond do
                    Enum.empty?(queue) ->
                        # add event to empty queue
                        List.wrap({action, event})

                    nevent.number === event.number ->
                        # old event alread in queue 
                        # at head do nothing
                        queue
                    true ->
                        # put new event in queue
                        queue
                        |> Enum.concat(List.wrap({action, event}))
                        |> Enum.uniq_by(&(elem(&1,1).number))
                        |> Enum.sort(&(elem(&1,1).number <= elem(&2,1).number))
                end

            push_now = 
                is_pid(pid) 
                and syn == ack 
                and number > ack 
                and nevent.number == number
                and instance.status === :running

            cond do
                push_now ->
                    [
                        app: instance.app,
                        process: instance.namespace,
                        saga: instance.id,
                        push: number,
                    ]
                    |> Signal.Logger.info(label: :router)

                    instance.app
                    |> Signal.PubSub.broadcast(instance.uuid, {naction, event})
                    %Instance{instance | syn: number, queue: queue}

                number > syn  ->
                    [
                        app: instance.app,
                        process: instance.namespace,
                        saga: instance.id,
                        status: instance.status,
                        queued: number
                    ]
                    |> Signal.Logger.info(label: :router)
                    %Instance{instance | queue: queue}

                true ->
                    instance
            end
        end

        def halt(%Instance{}=instance) do
            %Instance{app: app, ref: ref, uuid: uuid, ack: ack}=instance
            Process.demonitor(ref)
            Supervisor.unregister_child(app, uuid)
            Signal.PubSub.broadcast(app, uuid, :sleeping)

            # drop all apply actions
            # stop on first start
            # so instance can restart
            %Instance{instance| 
                pid: nil, 
                ref: nil, 
                syn: ack, 
                status: :sleeping
            }
        end

        def stop(%Instance{}=instance) do
            %Instance{
                app: app, 
                ref: ref, 
                ack: ack, 
                uuid: uuid, 
                queue: queue
            } = instance

            # drop all apply actions
            # stop on first start
            # so instance can restart
            flush = Enum.take_while(queue, &(elem(&1, 0) === :apply))
            fresh_queue = Enum.drop_while(queue, &(elem(&1, 0) === :apply))
            is_stoppable? = Enum.empty?(fresh_queue)

            if is_stoppable? do
                Process.demonitor(ref)
                Supervisor.unregister_child(app, uuid)
                Signal.PubSub.broadcast(app, uuid, :stopped)
            else
                Signal.PubSub.broadcast(app, uuid, :restart)
            end

            stopped_instance =
                %Instance{instance| 
                    pid: if(is_stoppable?, do: nil, else: instance.pid),
                    ref: if(is_stoppable?, do: nil, else: instance.ref),
                    syn: if(is_stoppable?, do: ack, else: instance.syn),
                    queue: fresh_queue,
                    status: if(is_stoppable?, do: :stopped, else: instance.status)
                }
            {stopped_instance, flush}
        end

        def stoppable?(%Instance{queue: queue}) do
            queue
            |> Enum.drop_while(&(elem(&1, 0) === :apply))
            |> Enum.empty?()
        end

        def acknowledge(%Instance{}=instance, number) do
            %Instance{ack: ack, syn: syn, queue: queue} = instance
            queue = Enum.filter(queue, &(elem(&1,1).number) > number)

            # Only acknowledge events with greater numbers
            # ie more recent events
            number = if number > ack, do: number, else: ack

            # On init ack syn === 0 
            # sync with ack from
            # process saga
            syn = if syn == 0 and number > syn, do: number, else: syn

            %Instance{instance| syn: syn, ack: number, queue: queue}
        end

    end

    @impl true
    def init(opts) do
        name = Keyword.fetch!(opts, :name)
        uuid = Effect.uuid(@router_namespace, name)
        opts = 
            opts
            |> Keyword.put(:uuid, uuid)
            |> Keyword.put(:instances, %{})
            |> Keyword.put(:processing, [])
            |> Keyword.put_new_lazy(:timeout, fn -> Signal.Timer.seconds(30) end)
        {:ok, struct(__MODULE__, opts), {:continue, :boot}}
    end


    @impl true
    def handle_continue(:boot, router) do
        Router.handle_boot(router)
    end

    @impl true
    def handle_continue({:route, event, reply}, router) do
        Router.handle_route({event, reply}, router)
    end

    @impl true
    def handle_info({:next, id}, router) do
        Router.handle_next(id, router)
    end

    @impl true
    def handle_info({:DOWN, ref, :process, _obj, _rsn}, router) do
        Router.handle_down(ref, router)
    end

    @impl true
    def handle_info(%Event{}=event, router) do
        Router.handle_event(event, router)
    end

    @impl true
    def handle_info({:stop, id}, router) do
        Router.handle_stop(id, router)
    end

    @impl true
    def handle_info({:sleep, id}, router) do
        Router.handle_sleep(id, router)
    end

    @impl true
    def handle_info({:start, id, number}, router) do
        Router.handle_start({id, number}, router)
    end

    @impl true
    def handle_info({:ack, id, number, _status}, router) do
        Router.handle_ack({id, number}, router)
    end

    @impl true
    def handle_info(:timeout, router) do
        Router.handle_timeout(router)
    end

    @impl true
    def handle_call({:alive, id}, _from, router) do
        Router.handle_alive(id, router)
    end

    def handle_boot(%Router{}=router) do
        router = 
            router
            |> load_router_instances()
            |> subscribe_router()
            |> track_router()
            
        {:noreply, router, router.timeout}
    end

    def handle_timeout(%Router{}=router) do
        {:noreply, router, :hibernate}
    end

    def handle_down(ref, %Router{instances: instances}=router) do
          instance = 
              instances
              |> Map.values()
              |> Enum.find(fn 
                  %Instance{ref: ^ref} -> 
                      true
                  _ ->
                      false
              end)

        if is_nil(instance) do
            {:noreply, router, router.timeout}
        else

            instance = Instance.halt(instance)

            case instance.queue do
                [] ->
                    instances = Map.put(instances, instance.id, instance)
                    {:noreply, %Router{router|instances: instances}, router.timeout}

                _ ->

                    %Instance{id: id, ack: ack} = instance

                    pid = start_process(router, id, ack) 

                    new_instance =
                        instance
                        |> Map.from_struct()
                        |> Map.put(:pid, pid)
                        |> Map.to_list()
                        |> Instance.new()

                    instances =  Map.put(instances, new_instance.id, new_instance)

                    {:noreply, %Router{router|instances: instances}, router.timeout}
            end

        end
    end

    def handle_start({id, number}, %Router{instances: instances}=router) do
        case Map.get(instances, id) do
            nil ->
                {:noreply, router, router.timeout}

            instance ->
                [
                    app: router.app,
                    process: router.name,
                    saga: id,
                    status: :started,
                    start: number,
                ]
                |> Signal.Logger.info(label: :router)

                updated_instance = 
                    instance
                    |> Instance.mark_as_running()

                sched_next(updated_instance)

                instances = Map.put(instances, instance.id, updated_instance)

                {:noreply, %Router{router| instances: instances}, router.timeout}
        end
    end

    def handle_ack({id, number}, %Router{instances: instances}=router) do
        [
            app: router.app,
            process: router.name,
            saga: id,
            status: :running,
            ack: number,
        ]
        |> Signal.Logger.info(label: :router)

        instance =
            instances
            |> Map.values()
            |> Enum.find(fn 
                %Instance{id: ^id, syn: ^number} -> 
                    true

                _ -> 
                    false
            end)

        router = 
            router
            |> mark_event_as_processed(number)
            |> acknowledge_processed_events()

        case instance do
            nil ->
                {:noreply, router, router.timeout}

            _ ->
                instance = 
                    instance
                    |> Instance.acknowledge(number)

                instances =  
                    instances
                    |> Map.put(instance.id, instance)

                router = 
                    router
                    |> struct(%{instances: instances})

                {:noreply, router, router.timeout}
        end
    end

    def handle_sleep(id, %Router{}=router) do
        %Router{instances: instances}=router

        [
            app: router.app,
            process: router.name,
            saga: id,
            status: :sleeping,
        ]
        |> Signal.Logger.info(label: :router)

        case Map.get(instances, id) do
            nil ->
                {:noreply, router, router.timeout}

            instance ->
                # Demonitor if process queue is empty
                # else ignor stopped event
                instances =
                    case instance do
                        %Instance{queue: [], syn: syn, ack: ack} when syn === ack ->
                            instance = Instance.halt(instance)
                            Map.put(instances, instance.id, instance)

                        %Instance{queue: _queue} ->
                            sched_next(instance)
                            Map.put(instances, instance.id, instance)
                    end

                {:noreply, %Router{router| instances: instances}, router.timeout}
        end
    end

    def handle_stop(id, %Router{}=router) do
        %Router{instances: instances}=router
        [
            app: router.app,
            process: router.name,
            saga: id,
            status: :stopped,
        ]
        |> Signal.Logger.info(label: :router)

        case Map.get(instances, id) do
            nil ->
                {:noreply, router, router.timeout}

            instance -> 
                {stopped_instance, needs_flush} = Instance.stop(instance)

                instances =
                    if stopped_instance.status === :stopped do
                        Map.delete(instances, id)
                    else
                        Map.put(instances, stopped_instance.id, stopped_instance)
                    end

                router = 
                    needs_flush
                    |> Enum.reduce(router, fn {_, %Event{number: number}}, router -> 
                        mark_event_as_processed(router, number)
                    end)
                    |> acknowledge_processed_events()
                    |> struct(%{instances: instances})

                {:noreply, router, router.timeout}
        end
    end

    def handle_alive(id, %Router{instances: instances}=router) do
        found =
            case Map.get(instances, id) do
                %Instance{} ->  
                    true
                _ -> 
                    false
            end
        {:reply, found, router, router.timeout}
    end

    def handle_event(%Event{}=event, %Router{module: module}=router) do

        reply = 
            case Kernel.apply(module, :handle, [Event.data(event)]) do
                {action, id} when (action in [:start, :apply]) and is_binary(id) ->
                    {action, id}

                :skip ->
                    {:skip, event.number}

                returned ->
                    raise """
                    process #{inspect(module)}.handle/1
                            expected return type of 
                            {:start, String.t()} | {:apply, String.t()} | :skip
                            got #{inspect(returned)}
                    """
            end

        {:noreply, router, {:continue, {:route, event, reply}}}
    end

    def handle_route({%Event{}=event, {action, id}}, %Router{}=router) do
        %Router{
            app: app, 
            name: namespace,
            instances: instances, 
        } = router

        [
            app: router.app,
            process: router.name,
            routing: event.topic,
            number: event.number,
            routing: {action, id},
        ]
        |> Signal.Logger.info(label: :router)

        target =
            case {action, Map.get(instances, id)} do
                {:start, %Instance{}=instance}  ->
                    instance

                {:apply, %Instance{}=instance} ->
                    instance

                {:start, nil}  ->
                    pid = start_process(router, id)
                    opts = [
                        id: id, 
                        app: app, 
                        pid: pid, 
                        namespace: namespace
                    ]
                    Instance.new(opts)

                _ ->  
                    nil
            end

        if target do

            instance = 
                router
                |> wake_process(target)
                |> Instance.push_event({action, event})

            instances = Map.put(instances, instance.id, instance)

            router = 
                router
                |> mark_event_as_processing(event.number, false)
                |> struct(%{instances: instances})

            {:noreply, router, router.timeout}
        else
            router = 
                router
                |> mark_event_as_processing(event.number, true)
                |> struct(%{instances: instances})
                |> acknowledge_processed_events()

            {:noreply, router, router.timeout}
        end
    end

    def handle_next(id, %Router{instances: instances}=router) do
        case Map.get(instances, id) do
            %Instance{queue: [{action, %Event{}=event}|_]} ->
                reply = {action, id}
                {:noreply, router, {:continue, {:route, event, reply}}}

            _ ->
                {:noreply, router, router.timeout}
        end
    end

    defp acknowledge_processed_events(%Router{processing: []}=router) do
        router
    end

    defp acknowledge_processed_events(%Router{processing: [{_, false}|_]}=router) do
        router
    end

    defp acknowledge_processed_events(%Router{}=router) do
        %Router{
            app: app, 
            consumer:  consumer,
            processing: [{number, true}| processing]
        } = router

        if number > consumer.ack  do
            [
                app: router.app,
                process: router.name, 
                ack: number
            ]
            |> Signal.Logger.info(label: :router)

            consumer = 
                app
                |> Broker.acknowledge(consumer, number)

            %Router{router| 
                consumer: consumer,
                processing: processing,
            }
            |> acknowledge_processed_events()
        else
            router
        end
    end

    defp sched_next(%Instance{queue: []}) do
        nil
    end

    defp sched_next(%Instance{id: id, status: :running}) do
        Process.send(self(), {:next, id}, [])
    end

    defp start_process(router, id, index \\ 0)
    defp start_process(%Router{}=router, id, index) do
        suuid = Effect.uuid(router.name, id)
        opts = [
            id: id, 
            app: router.app, 
            uuid: suuid, 
            start: index,
            module: router.module, 
            channel: router.uuid,
            namespace: router.name, 
        ]
        router.app
        |> Saga.start({suuid, router.module}, opts)
        |> GenServer.whereis()
    end

    defp wake_process(%Router{}=router, %Instance{pid: nil, status: :sleeping}=inst) do
        pid = start_process(router, inst.id, inst.ack)
        inst
        |> Map.from_struct() 
        |> Map.put(:pid, pid)
        |> Map.to_list()
        |> Instance.new()
    end

    defp wake_process(%Router{}, %Instance{}=instance) do
        instance
    end

    defp subscribe_router(%Router{}=router) do
        %Router{
            app: app, 
            name: name, 
            uuid: uuid,
            topics: topics, 
        }=router

        subopts = [topics: topics, start: :cursor, track: true]

        consumer = 
            app
            |> Broker.subscribe(name, subopts)

        app
        |> Signal.PubSub.subscribe(uuid)

        %Router{router | consumer: consumer}
    end

    defp load_router_instances(%Router{}=router) do
        %Router{app: app, name: name, module: module}=router

        common = [app: app, namespace: name, module: module]

        instances =
            app
            |> Signal.Store.Adapter.list_effects(name)
            |> Enum.reduce(router.instances, fn %Effect{data: data}, instances -> 
                id = Map.get(data, "id")
                ack = Map.get(data, "ack")
                buffer = Map.get(data, "buffer")
                actions = Map.get(data, "actions")
                stopped = Map.get(data, "stopped")
                instance =
                    case {actions, buffer} do
                        # No events and actions
                        # and process is not stopping
                        # then assume process as sleeping
                        {[], []} when stopped === false ->
                            common
                            |> Keyword.merge([id: id, ack: ack])
                            |> Instance.new()

                          _ ->
                            pid = start_process(router, id, ack)
                            common
                            |> Keyword.merge([id: id, ack: ack, pid: pid])
                            |> Instance.new()
                    end
                Map.put(instances, instance.id, instance)
            end)

        %Router{router | instances: instances}
    end

    defp track_router(%Router{}=router) do
        metadata = %{
            ts: DateTime.utc_now(),
            name: router.name,
            topics: router.topics,
            process: router.module,
            timeout: router.timeout,
            ack: router.consumer.ack,
        }
        router.app
        |> Signal.Tracker.track("router", router.name, metadata)
        router
    end

    defp mark_event_as_processing(%Router{}=router, number, ack) do
        processing =
            router.processing
            |> Enum.concat([{number, ack}])
            |> Enum.uniq_by(&(elem(&1,0)))
            |> Enum.sort(&(elem(&1,0) <= elem(&2,0)))

        %Router{router| processing: processing}
    end

    defp mark_event_as_processed(%Router{}=router, number) do
        %Router{processing: processing} = router
        index = Enum.find_index(processing, &(elem(&1, 0) === number))

        processing =
            if index do
                List.replace_at(processing, index, {number, true})
            else
                processing
            end
        %Router{router| processing: processing}
    end


end
