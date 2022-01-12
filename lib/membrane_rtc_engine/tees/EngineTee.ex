defmodule Membrane.RTC.Engine.Tee do
  @moduledoc """
  Element for forwarding buffers to at least one output pad

  It has one input pad `:input` and 2 output pads:
  * `:master` - is a static pad which is always available and works in pull mode
  * `:copy` - is a dynamic pad that can be linked to any number of elements (including 0) and works in push mode

  The `:master` pad dictates the speed of processing data and any element (or elements) connected to `:copy` pad
  will receive the same data as `:master`.

  It has got built-in mechanism for limiting forwarding video buffers.
  It reads from ETS table on which pads it should forward buffers.
  """

  use Membrane.Filter

  def_options track_id: [
                spec: String.t(),
                description: "Id of track for which tee was created"
              ],
              ets_name: [
                spec: String.t(),
                description:
                  "Name of ETS table from which Tee will read to which pads it should send buffers",
                default: "table"
              ],
              type: [
                spec: :audio | :video,
                description: "Type of track which buffers tee is forwarding"
              ]

  def_input_pad :input,
    availability: :always,
    mode: :pull,
    demand_unit: :buffers,
    caps: :any

  def_output_pad :master,
    availability: :always,
    mode: :pull,
    caps: :any

  def_output_pad :copy,
    availability: :on_request,
    mode: :push,
    caps: :any

  @impl true
  def handle_init(opts) do
    {:ok,
     %{
       ets_name: :"#{opts.ets_name}",
       track_id: opts.track_id,
       counter: 0,
       type: opts.type,
       forward_to: MapSet.new()
     }}
  end

  @impl true
  def handle_process(:input, %Membrane.Buffer{} = buffer, _ctx, %{type: :audio} = state) do
    {{:ok, forward: buffer}, state}
  end

  @impl true
  def handle_process(
        :input,
        %Membrane.Buffer{} = buffer,
        _ctx,
        %{type: :video, counter: 1000} = state
      ) do
    {{:ok, forward: buffer},
     %{state | counter: 0, forward_to: get_new_forward_to(state.ets_name, state.track_id)}}
  end

  @impl true
  def handle_process(:input, %Membrane.Buffer{} = buffer, ctx, %{type: :video} = state) do
    pads =
      ctx.pads
      |> Map.keys()
      |> Enum.filter(fn
        {Membrane.Pad, :copy, {:endpoint, _endpoint_id} = endpoint_name} ->
          MapSet.member?(state.forward_to, endpoint_name)

        {Membrane.Pad, :copy, _ref} ->
          true

        _other ->
          false
      end)

    pads = pads ++ [:master]
    actions = Enum.map(pads, &{:buffer, {&1, buffer}})

    {{:ok, actions}, %{state | counter: state.counter + 1}}
  end

  @impl true
  def handle_demand(:master, size, :buffers, _ctx, state) do
    {{:ok, demand: {:input, size}}, state}
  end

  @impl true
  def handle_other(:update_forward, _ctx, state) do
    {:ok, %{state | forward_to: get_new_forward_to(state.ets_name, state.track_id)}}
  end

  defp get_new_forward_to(ets_name, track_id) do
    case :ets.lookup(ets_name, track_id) do
      [{_track_id, value} | _] ->
        MapSet.new(value)

      [] ->
        MapSet.new()
    end
  end
end
