module PlutoBindServer

include("./MoreAnalysis.jl")
import .MoreAnalysis

import Pluto
import Pluto: ServerSession, Firebasey, Token, withtoken
using HTTP
using Base64
using SHA
using Sockets
using JSON
import UUIDs: UUID

myhash = base64encode ∘ sha256


Base.@kwdef struct SwankyNotebookSession
    hash::String
    notebook::Pluto.Notebook
    original_state
    token::Token=Token()
    bond_connections::Dict{Symbol,Vector{Symbol}}
end

function with_msgpack!(response::HTTP.Response)
    push!(response.headers, "Content-Type" => "application/msgpack")
    response
end

function with_json!(response::HTTP.Response)
    push!(response.headers, "Content-Type" => "application/json")
    response
end

function with_cors!(response::HTTP.Response)
    push!(response.headers, "Access-Control-Allow-Origin" => "*")
    response
end

function with_cachable!(response::HTTP.Response)
    second = 1
    minute = 60second
    hour = 60minute
    day = 24hour
    year = 365day

    push!(response.headers, "Cache-Control" => "public, max-age=$(10year), immutable")
    response
end

function with_not_cachable!(response::HTTP.Response)
    push!(response.headers, "Cache-Control" => "no-store, no-cache, max-age=5")
    response
end



"""
    run_directory(start_dir::String="."; kwargs...)

Run the Pluto bind server for all Pluto notebooks in the given directory (recursive search). 

Additional keyword arguments can be given to the Pluto.run constructor. Note that **security is always disabled**.
"""
function run_directory(start_dir::String="."; kwargs...)
    notebookfiles = let
        jlfiles = vcat(map(walkdir(start_dir)) do (root, dirs, files)
            map(
                filter(files) do file
                    occursin(".jl", file)
                end
                ) do file
                joinpath(root, file)
            end
        end...)
        filter(jlfiles) do f
            !occursin(".julia", f) &&
            readline(f) == "### A Pluto.jl notebook ###"
        end
    end
    
    @info "Found Pluto notebooks:" notebookfiles

    PlutoBindServer.run_paths(notebookfiles; kwargs...)
end



function run_paths(notebook_paths::Vector{String}; copy_to_temp_before_running=false, create_statefiles=false, kwargs...)
    @warn "Make sure that you run this bind server inside a containerized environment -- it is not intended to be secure. Assume that users can execute arbitrary code inside your notebooks."

    options = Pluto.Configuration.from_flat_kwargs(; kwargs...)
    session = Pluto.ServerSession(;options=options)

    router_ref = Ref{HTTP.Router}(empty_router())

    # This is boilerplate HTTP code, don't read it
    host = session.options.server.host
    port = session.options.server.port

    # This is boilerplate HTTP code, don't read it
    hostIP = parse(Sockets.IPAddr, host)
    if port === nothing
        port, serversocket = Sockets.listenany(hostIP, UInt16(1234))
    else
        try
            serversocket = Sockets.listen(hostIP, UInt16(port))
        catch e
            @error "Port with number $port is already in use. Use Pluto.run() to automatically select an available port."
            return
        end
    end

    @info "Starting server..." host Int(port)

    # This is boilerplate HTTP code, don't read it
    # We start the HTTP server before launching notebooks so that the server responds to heroku/digitalocean garbage fast enough
    http_server_task = @async HTTP.serve(hostIP, UInt16(port), stream=true, server=serversocket) do http::HTTP.Stream
        request::HTTP.Request = http.message
        request.body = read(http)
        HTTP.closeread(http)

        params = HTTP.queryparams(HTTP.URI(request.target))

        response_body = HTTP.handle(router_ref[], request)

        request.response::HTTP.Response = response_body
        request.response.request = request
        try
            HTTP.setheader(http, "Referrer-Policy" => "origin-when-cross-origin")
            HTTP.startwrite(http)
            write(http, request.response.body)
            HTTP.closewrite(http)
        catch e
            if isa(e, Base.IOError) || isa(e, ArgumentError)
                # @warn "Attempted to write to a closed stream at $(request.target)"
            else
                rethrow(e)
            end
        end
    end

    # RUN ALL NOTEBOOKS AND KEEP THEM RUNNING
    swanky_sessions = map(enumerate(notebook_paths)) do (i, path)
        @info "Opening $(path)"
        hash = myhash(read(path))
        if copy_to_temp_before_running
            newpath = tempname()
            write(newpath, read(path))
        else
            newpath = path
        end
        # run the notebook! synchronously
        nb = Pluto.SessionActions.open(session, newpath; run_async=false)
        state = Pluto.notebook_to_js(nb)

        if create_statefiles
            # becomes .jlstate
            write(newpath * "state", Pluto.pack(state))
        end

        connections = MoreAnalysis.bound_variable_connections_graph(nb)

        @info "[$(i)/$(length(notebook_paths))] Ready $(path)" hash connections

        SwankyNotebookSession(
            hash=hash, 
            notebook=nb, 
            original_state=state, 
            bond_connections=connections
        )
    end
    
    router_ref[] = make_router(session, swanky_sessions)

    @info "-- SERVER READY --"

    wait(http_server_task)
end


# create router

function make_router(session::ServerSession, swanky_sessions::AbstractVector{SwankyNotebookSession})
    router = HTTP.Router()

    function get_sesh(request::HTTP.Request)
        uri = HTTP.URI(request.target)
    
        parts = HTTP.URIs.splitpath(uri.path)
        # parts[1] == "staterequest"
        notebook_hash = parts[2] |> HTTP.unescapeuri

        i = findfirst(swanky_sessions) do sesh
            sesh.hash == notebook_hash
        end
        
        response = if i === nothing
            #= 
            ERROR HINT

            This means that the notebook file used by the web client does not precisely match any of the notebook files running in this server. 

            If this is an automated setup, then this could happen inbetween deployments. 
            
            If this is a manual setup, then running the .jl notebook file might have caused a small change (e.g. the version number or a whitespace change). Copy notebooks to a temporary directory before running them using the bind server. =#
            @info "Request hash not found. See errror hint in my source code." notebook_hash
            nothing
        else
            sesh = swanky_sessions[i]
        end
    end

    function get_bonds(request::HTTP.Request)
        request_body = if request.method == "POST"
            IOBuffer(HTTP.payload(request))
        elseif request.method == "GET"
            uri = HTTP.URI(request.target)
    
            parts = HTTP.URIs.splitpath(uri.path)
            # parts[1] == "staterequest"
            # notebook_hash = parts[2] |> HTTP.unescapeuri

            @assert length(parts) == 3

            base64decode(parts[3] |> HTTP.unescapeuri)
        end
        bonds_raw = Pluto.unpack(request_body)

        Dict(Symbol(k) => v for (k, v) in bonds_raw)
    end

    "Happens whenever you mvoe a slider"
    function serve_staterequest(request::HTTP.Request)
        sesh = get_sesh(request)        
        
        response = if sesh === nothing
            HTTP.Response(404, "Not found!") |> with_cors! |> with_not_cachable!
        else
            notebook = sesh.notebook

            
            bonds = try
                get_bonds(request)
                
            catch e
                @error "Failed to deserialize bond values" exception=(e, catch_backtrace())
                return HTTP.Response(500, "Failed to deserialize bond values") |> with_cors! |> with_not_cachable!
            end

            @debug "Deserialized bond values" bonds

            sleep(session.options.server.simulated_lag)

            topological_order, new_state = withtoken(sesh.token) do
                try
                    notebook.bonds = bonds

                    names::Vector{Symbol} = Symbol.(keys(bonds))

                    # TODO: is_first_value should be determined by the client
                    topological_order = Pluto.set_bond_values_reactive(
                        session=session,
                        notebook=notebook,
                        bound_sym_names=names,
                        is_first_value=false,
                        run_async=false,
                    )::Pluto.TopologicalOrder

                    new_state = Pluto.notebook_to_js(notebook)

                    topological_order, new_state
                catch e
                    @error "Failed to set bond values" exception=(e, catch_backtrace())
                    nothing, nothing
                end
            end

            
            # @show [c.cell_id for c in topological_order.runnable]
            topological_order === nothing && return (HTTP.Response(500, "Failed to set bond values") |> with_cors! |> with_not_cachable!)

            ids_of_cells_that_ran = [c.cell_id for c in topological_order.runnable]

            @debug "Finished running!" length(ids_of_cells_that_ran)

            # We only want to send state updates about...
            function only_relevant(state)
                new = copy(state)
                # ... the cells that just ran and ...
                new["cell_results"] = filter(state["cell_results"]) do (id, cell_state)
                    id ∈ ids_of_cells_that_ran
                end
                # ... nothing about bond values, because we don't want to synchronize among clients.
                new["bonds"] = Dict{String,Dict{String,Any}}()
                new
            end

            patches = Firebasey.diff(only_relevant(sesh.original_state), only_relevant(new_state))
            patches_as_dicts::Array{Dict} = patches

            HTTP.Response(200, Pluto.pack(Dict{String,Any}(
                "patches" => patches_as_dicts,
                "ids_of_cells_that_ran" => ids_of_cells_that_ran,
            ))) |> with_cachable! |> with_cors! |> with_msgpack!
        end
    end

    function serve_bondconnections(request::HTTP.Request)        
        sesh = get_sesh(request)        
        
        response = if sesh === nothing
            HTTP.Response(404, "Not found!") |> with_cors! |> with_not_cachable!
        else
            HTTP.Response(200, Pluto.pack(sesh.bond_connections)) |> with_cors! |> with_cachable! |> with_msgpack!
        end
        response
    end

    function serve_interface(request::HTTP.Request)
        sesh = get_sesh(request)
        uri = HTTP.URI(request.target)
        query = HTTP.queryparams(uri)

        parts = HTTP.URIs.splitpath(uri.path)
        out_symbols = Symbol.(parts[3] |> HTTP.unescapeuri |> split)

        notebook = sesh.notebook
        topology = notebook.topology

        body = JSON.parse(String(request.body))

        assigned = Pluto.where_assigned(notebook, topology, Set(out_symbols))
        root_symbols = (x->topology[x].definitions).(MoreAnalysis.upstream_roots(notebook, topology, assigned))
        to_set = length(root_symbols) > 0 ? reduce(∪, root_symbols) : Set{Symbol}()
        provided_set = Symbol.(keys(body))

        new_values = values(body)
        output_cell = Pluto.where_assigned(notebook, topology, Set{Symbol}(out_symbols))[1]

        to_reeval = [
            # Re-evaluate all cells that reference the modified input parameters
            Pluto.where_referenced(notebook, notebook.topology, Set{Symbol}(to_set))...,
            # Re-evaluate all input cells that were not provided as parameters
            Pluto.where_assigned(notebook, notebook.topology, Set{Symbol}(filter(x->(x ∉ provided_set), to_set)))...
        ]

        function custom_deletion_hook((session, notebook)::Tuple{ServerSession,Pluto.Notebook}, to_delete_vars::Set{Symbol}, funcs_to_delete::Set{Tuple{UUID,Pluto.FunctionName}}, to_reimport::Set{Expr}; to_run::AbstractVector{Pluto.Cell})
            to_delete_vars = Set([to_delete_vars..., to_set...]) # also delete the bound symbols
            Pluto.WorkspaceManager.delete_vars((session, notebook), to_delete_vars, funcs_to_delete, to_reimport)
            for (sym, new_value) in zip(to_set, new_values)
                Pluto.WorkspaceManager.eval_in_workspace((session, notebook), :($(sym) = $(new_value)))
            end
        end

        Pluto.update_save_run!(session, notebook, to_reeval; deletion_hook=custom_deletion_hook, save=false)

        outputs = Dict(out_symbol => Pluto.WorkspaceManager.eval_fetch_in_workspace((session, notebook), out_symbol) for out_symbol in out_symbols)

        HTTP.Response(200, JSON.json(outputs)) |> with_json!
    end

    function serve_topparams(request::HTTP.Request)
        sesh = get_sesh(request)
        uri = HTTP.URI(request.target)
        query = HTTP.queryparams(uri)

        notebook = sesh.notebook
        topology = notebook.topology

        out = get(query, "out", "")

        assigned = Pluto.where_assigned(notebook, topology, Set([Symbol(out)]))[1]

        top_nodes = MoreAnalysis.upstream_roots(notebook, topology, assigned)

        params_list = [topology[cell].definitions for cell ∈ top_nodes]
        params = length(params_list) > 0 ? reduce(∪, params_list) : Set()

        res = HTTP.Response(200, JSON.json(params)) |> with_json!
    end
    
    HTTP.@register(router, "GET", "/", r -> (HTTP.Response(200, "Hi!") |> with_cors! |> with_not_cachable!))
    
    # !!!! IDEAAAA also have a get endpoint with the same thing but the bond data is base64 encoded in the URL
    # only use it when the amount of data is not too much :o

    HTTP.@register(router, "POST", "/staterequest/*/", serve_staterequest)
    HTTP.@register(router, "GET", "/staterequest/*/*", serve_staterequest)
    HTTP.@register(router, "GET", "/bondconnections/*/", serve_bondconnections)
    HTTP.@register(router, "POST", "/interface/*/*/", serve_interface)
    HTTP.@register(router, "POST", "/topparams/*/", serve_topparams)

    router
end

function empty_router()
    router = HTTP.Router()
    HTTP.@register(router, "GET", "/", r -> (HTTP.Response(503, "Still loading the notebooks... check back later!") |> with_cors! |> with_not_cachable!))
    router
end


end
