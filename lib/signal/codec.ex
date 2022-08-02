defprotocol Signal.Codec do

    @fallback_to_any true

    @spec encode(t) :: String.t()
    def encode(type)

    @spec load(t, p :: map) :: term()
    def load(type, payload)

end

defimpl Signal.Codec, for: Any do

    def encode(%{__struct__: type}=data) when is_struct(data) do
        type.dump(data, [])
    end

    def load(%{__struct__: type}, payload) do
        type.cast(payload, [])
    end
    
end



