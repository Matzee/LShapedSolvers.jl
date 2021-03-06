# ------------------------------------------------------------
# Parallel -> Algorithm is run in parallel
# ------------------------------------------------------------
@define_trait Parallel

@define_traitfn Parallel init_subproblems!(lshaped::AbstractLShapedSolver{F,T,A,M,S}, subsolver::SubSolver) where {F, T <: Real, A <: AbstractVector, M <: LQSolver, S <: LQSolver} = begin
    function init_subproblems!(lshaped::AbstractLShapedSolver{F,T,A,M,S}, subsolver::SubSolver, !Parallel) where {F, T <: Real, A <: AbstractVector, M <: LQSolver, S <: LQSolver}
        # Prepare the subproblems
        load_subproblems!(lshaped, scenarioproblems(lshaped.stochasticprogram), subsolver)
        append!(lshaped.subobjectives, zeros(nbundles(lshaped)))
        return lshaped
    end

    function init_subproblems!(lshaped::AbstractLShapedSolver{F,T,A,M,S}, subsolver::SubSolver, Parallel) where {F, T <: Real, A <: AbstractVector, M <: LQSolver, S <: LQSolver}
        @unpack κ = lshaped.parameters
        # Load initial decision
        put!(lshaped.decisions, 1, lshaped.x)
        # Create subproblems on worker processes
        @sync begin
            for w in workers()
                lshaped.subworkers[w-1] = RemoteChannel(() -> Channel{Vector{SubProblem{F,T,A,S}}}(1), w)
                @async load_worker!(scenarioproblems(lshaped.stochasticprogram), w, lshaped.subworkers[w-1], lshaped.x, subsolver, lshaped.parameters.bundle)
            end
            # Prepare memory
            push!(lshaped.subobjectives, zeros(nbundles(lshaped)))
            push!(lshaped.finished, 0)
            log_val = lshaped.parameters.log
            lshaped.parameters.log = false
            log!(lshaped)
            lshaped.parameters.log = log_val
        end
        # Prepare work channels
        for w in workers()
            lshaped.work[w-1] = RemoteChannel(() -> Channel{Int}(10), w)
            put!(lshaped.work[w-1], 1)
        end
        return lshaped
    end
end

@define_traitfn Parallel iterate!(lshaped::AbstractLShapedSolver) = begin
    function iterate!(lshaped::AbstractLShapedSolver, !Parallel)
        iterate_nominal!(lshaped)
    end

    function iterate!(lshaped::AbstractLShapedSolver, Parallel)
        iterate_parallel!(lshaped)
    end
end

@define_traitfn Parallel nbundles(lshaped::AbstractLShapedSolver) = begin
    function nbundles(lshaped::AbstractLShapedSolver, !Parallel)
        return ceil(Int, lshaped.nscenarios/lshaped.parameters.bundle)
    end

    function nbundles(lshaped::AbstractLShapedSolver, Parallel)
        return nbundles(lshaped, scenarioproblems(lshaped.stochasticprogram))
    end
end

function nbundles(lshaped::AbstractLShapedSolver, sp::StochasticPrograms.ScenarioProblems)
    jobsize = ceil(Int, lshaped.nscenarios/nworkers())
    n = ceil(Int, jobsize/lshaped.parameters.bundle)
    remainder = lshaped.nscenarios-(nworkers()-1)*jobsize
    bundlerem = ceil(Int, remainder/lshaped.parameters.bundle)
    return n*(nworkers()-1)+bundlerem
end

function nbundles(lshaped::AbstractLShapedSolver, sp::StochasticPrograms.DScenarioProblems)
    return sum([ceil(Int, nscen/lshaped.parameters.bundle) for nscen in sp.scenario_distribution])
end

@define_traitfn Parallel init_workers!(lshaped::AbstractLShapedSolver) = begin
    function init_workers!(lshaped::AbstractLShapedSolver, Parallel)
        for w in workers()
            lshaped.active_workers[w-1] = remotecall(work_on_subproblems!,
                                                     w,
                                                     lshaped.subworkers[w-1],
                                                     lshaped.work[w-1],
                                                     lshaped.cutqueue,
                                                     lshaped.decisions,
                                                     lshaped.parameters.bundle)
        end
        return nothing
    end
end

@define_traitfn Parallel close_workers!(lshaped::AbstractLShapedSolver) = begin
    function close_workers!(lshaped::AbstractLShapedSolver, Parallel)
        map((w)->close(w), lshaped.work)
        map(wait, lshaped.active_workers)
        return nothing
    end
end

@define_traitfn Parallel calculate_objective_value(lshaped::AbstractLShapedSolver, x::AbstractVector) = begin
    function calculate_objective_value(lshaped::AbstractLShapedSolver, x::AbstractVector, !Parallel)
        return lshaped.c⋅x + sum([subproblem.π*subproblem(x) for subproblem in lshaped.subproblems])
    end

    function calculate_objective_value(lshaped::AbstractLShapedSolver, x::AbstractVector, Parallel)
        Qs = Vector{Float64}(undef, nworkers())
        @sync begin
            for (w,worker) in enumerate(lshaped.subworkers)
                @async Qs[w] = remotecall_fetch(calculate_subobjective, w+1, worker, x)
            end
        end
        return lshaped.c⋅x + sum(Qs)
    end
end

@define_traitfn Parallel fill_submodels!(lshaped::AbstractLShapedSolver, scenarioproblems::StochasticPrograms.ScenarioProblems) = begin
    function fill_submodels!(lshaped::AbstractLShapedSolver, scenarioproblems::StochasticPrograms.ScenarioProblems, !Parallel)
        for (i, submodel) in enumerate(scenarioproblems.problems)
            lshaped.subproblems[i](decision(lshaped))
            fill_submodel!(submodel, lshaped.subproblems[i])
        end
    end

    function fill_submodels!(lshaped::AbstractLShapedSolver, scenarioproblems::StochasticPrograms.ScenarioProblems, Parallel)
        j = 0
        @sync begin
            for w in workers()
                n = remotecall_fetch((sw)->length(fetch(sw)), w, lshaped.subworkers[w-1])
                for i = 1:n
                    k = i+j
                    @async fill_submodel!(scenarioproblems.problems[k],remotecall_fetch((sw,i,x)->begin
                        sp = fetch(sw)[i]
                        sp(x)
                        get_solution(sp)
                    end,
                    w,
                    lshaped.subworkers[w-1],
                    i,
                    decision(lshaped))...)
                end
                j += n
            end
        end
    end
end

@define_traitfn Parallel fill_submodels!(lshaped::AbstractLShapedSolver, scenarioproblems::StochasticPrograms.DScenarioProblems) = begin
    function fill_submodels!(lshaped::AbstractLShapedSolver, scenarioproblems::StochasticPrograms.DScenarioProblems, !Parallel)
        j = 0
        @sync begin
            for w in workers()
                n = remotecall_fetch((sp)->length(fetch(sp).problems), w, scenarioproblems[w-1])
                for i in 1:n
                    k = i+j
                    lshaped.subproblems[k](decision(lshaped))
                    @async remotecall_fetch((sp,i,x,μ,λ,C) -> fill_submodel!(fetch(sp).problems[i],x,μ,λ,C),
                                            w,
                                            scenarioproblems[w-1],
                                            i,
                                            get_solution(lshaped.subproblems[k])...)
                end
                j += n
            end
        end
    end

    function fill_submodels!(lshaped::AbstractLShapedSolver, scenarioproblems::StochasticPrograms.DScenarioProblems, Parallel)
        @sync begin
            for w in workers()
                @async remotecall_fetch(fill_submodels!,
                                        w,
                                        lshaped.subworkers[w-1],
                                        decision(lshaped),
                                        scenarioproblems[w-1])
            end
        end
    end
end

# Parallel routines #
# ======================================================================== #
mutable struct DecisionChannel{A <: AbstractArray} <: AbstractChannel{A}
    decisions::Dict{Int,A}
    cond_take::Condition
    DecisionChannel(decisions::Dict{Int,A}) where A <: AbstractArray = new{A}(decisions, Condition())
end

function put!(channel::DecisionChannel, t, x)
    channel.decisions[t] = copy(x)
    notify(channel.cond_take)
    return channel
end

function take!(channel::DecisionChannel, t)
    x = fetch(channel, t)
    delete!(channel.decisions, t)
    return x
end

isready(channel::DecisionChannel) = length(channel.decisions) > 1
isready(channel::DecisionChannel, t) = haskey(channel.decisions, t)

function fetch(channel::DecisionChannel, t)
    wait(channel, t)
    return channel.decisions[t]
end

function wait(channel::DecisionChannel, t)
    while !isready(channel, t)
        wait(channel.cond_take)
    end
end

SubWorker{F,T,A,S} = RemoteChannel{Channel{Vector{SubProblem{F,T,A,S}}}}
ScenarioProblems{D,S} = RemoteChannel{Channel{StochasticPrograms.ScenarioProblems{D,S}}}
Work = RemoteChannel{Channel{Int}}
Decisions{A} = RemoteChannel{DecisionChannel{A}}
QCut{T} = Tuple{Int,T,SparseHyperPlane{T}}
CutQueue{T} = RemoteChannel{Channel{QCut{T}}}

function load_subproblems!(lshaped::AbstractLShapedSolver{F,T,A}, scenarioproblems::StochasticPrograms.ScenarioProblems, subsolver::MPB.AbstractMathProgSolver) where {F, T <: Real, A <: AbstractVector}
    id = 1
    for i = 1:lshaped.nscenarios
        m = subproblem(scenarioproblems, i)
        y₀ = convert(A, rand(m.numCols))
        push!(lshaped.subproblems,SubProblem(m,
                                             parentmodel(scenarioproblems),
                                             id,
                                             probability(scenario(scenarioproblems,i)),
                                             copy(lshaped.x),
                                             y₀,
                                             subsolver,
                                             F))
        if i % lshaped.parameters.bundle == 0
            id += 1
        end
    end
    return lshaped
end

function load_subproblems!(lshaped::AbstractLShapedSolver{F,T,A}, scenarioproblems::StochasticPrograms.DScenarioProblems, subsolver::MPB.AbstractMathProgSolver) where {F, T <: Real, A <: AbstractVector}
    id = 1
    for i = 1:lshaped.nscenarios
        m = subproblem(scenarioproblems, i)
        y₀ = convert(A, rand(m.numCols))
        push!(lshaped.subproblems,SubProblem(m,
                                             id,
                                             probability(scenario(scenarioproblems,i)),
                                             copy(lshaped.x),
                                             y₀,
                                             masterterms(scenarioproblems,i),
                                             subsolver,
                                             F))
        if i % lshaped.parameters.bundle == 0
            id += 1
        end
    end
    return lshaped
end

function load_worker!(sp::StochasticPrograms.ScenarioProblems,
                      w::Integer,
                      worker::SubWorker,
                      x::AbstractVector,
                      subsolver::SubSolver,
                      bundlesize::Integer)
    n = StochasticPrograms.nscenarios(sp)
    (nscen, extra) = divrem(n, nworkers())
    prev = [nscen + (extra + 2 - p > 0) for p in 2:(w-1)]
    start = isempty(prev) ? 1 : sum(prev) + 1
    stop = min(start + nscen + (extra + 2 - w > 0) - 1, n)
    prev = [begin
            jobsize = nscen + (extra + 2 - p > 0)
            ceil(Int, jobsize/bundlesize)
            end for p in 2:(w-1)]
    start_id = isempty(prev) ? 1 : sum(prev) + 1
    πs = [probability(sp.scenarios[i]) for i = start:stop]
    return remotecall_fetch(init_subworker!,
                            w,
                            worker,
                            sp.parent,
                            sp.problems[start:stop],
                            πs,
                            x,
                            subsolver,
                            bundlesize,
                            start_id)
end

function load_worker!(sp::StochasticPrograms.DScenarioProblems,
                      w::Integer,
                      worker::SubWorker,
                      x::AbstractVector,
                      subsolver::SubSolver,
                      bundlesize::Integer)
    prev = [ceil(Int,sp.scenario_distribution[p-1]/bundlesize) for p in 2:(w-1)]
    start_id = isempty(prev) ? 1 : sum(prev)+1
    return remotecall_fetch(init_subworker!,
                            w,
                            worker,
                            sp[w-1],
                            x,
                            subsolver,
                            bundlesize,
                            start_id)
end

function init_subworker!(subworker::SubWorker{F,T,A,S},
                         parent::JuMP.Model,
                         submodels::Vector{JuMP.Model},
                         πs::A,
                         x::A,
                         subsolver::SubSolver,
                         bundlesize::Integer,
                         start_id::Integer) where {F, T <: Real, A <: AbstractArray, S <: LQSolver}
    subproblems = Vector{SubProblem{F,T,A,S}}(undef, length(submodels))
    id = start_id
    for (i,submodel) = enumerate(submodels)
        y₀ = convert(A, rand(submodel.numCols))
        subproblems[i] = SubProblem(submodel, parent, id, πs[i], x, y₀, get_solver(subsolver), F)
        if i % bundlesize == 0
            id += 1
        end
    end
    put!(subworker, subproblems)
    return nothing
end

function init_subworker!(subworker::SubWorker{F,T,A,S},
                         scenarioproblems::ScenarioProblems,
                         x::A,
                         subsolver::SubSolver,
                         bundlesize::Integer,
                         start_id::Integer) where {F, T <: Real, A <: AbstractArray, S <: LQSolver}
    sp = fetch(scenarioproblems)
    subproblems = Vector{SubProblem{F,T,A,S}}(undef, StochasticPrograms.nsubproblems(sp))
    id = start_id
    for (i,submodel) = enumerate(sp.problems)
        y₀ = convert(A, rand(sp.problems[i].numCols))
        subproblems[i] = SubProblem(submodel, sp.parent, id, probability(sp.scenarios[i]), x, y₀, get_solver(subsolver), F)
        if i % bundlesize == 0
            id += 1
        end
    end
    put!(subworker, subproblems)
    return nothing
end

function work_on_subproblems!(subworker::SubWorker{F,T,A,S},
                              work::Work,
                              cuts::CutQueue{T},
                              decisions::Decisions{A},
                              bundlesize::Int) where {F, T <: Real, A <: AbstractArray, S <: LQSolver}
    subproblems::Vector{SubProblem{F,T,A,S}} = fetch(subworker)
    if isempty(subproblems)
       # Workers has nothing do to, return.
       return
    end
    @sync while true
        t::Int = try
            wait(work)
            take!(work)
        catch err
            if err isa InvalidStateException
                # Master closed the work channel. Worker finished
                return
            end
        end
        if t == -1
            # Worker finished
            return
        end
        x::A = fetch(decisions,t)
        if bundlesize == 1
            for subproblem in subproblems
                @async begin
                    update_subproblem!(subproblem, x)
                    cut = subproblem()
                    Q::T = cut(x)
                    put!(cuts, (t,Q,cut))
                end
            end
        else
            njobs = ceil(Int, length(subproblems)/bundlesize)
            for i = 1:njobs
                @async begin
                    cut_bundle = CutBundle(T)
                    for subproblem in subproblems[(i-1)*bundlesize+1:min(i*bundlesize,length(subproblems))]
                        update_subproblem!(subproblem, x)
                        cut::SparseHyperPlane{T} = subproblem()
                        _add_cut(cuts, t, cut,x)
                        _add_to_bundle!(cut_bundle, cut, x)
                    end
                    if cut_bundle.q < Inf
                        put!(cuts, (t,cut_bundle.q,aggregate!(cut_bundle)))
                    end
                end
            end
        end
    end
end

function _add_cut(cuts::CutQueue, t::Integer, cut::HyperPlane, x::AbstractArray)
    put!(cuts, (t,cut(x),cut))
end
function _add_cut(cuts::CutQueue, t::Integer, cut::HyperPlane{OptimalityCut}, x::AbstractArray)
    nothing
end
function _add_to_bundle!(bundle::CutBundle, cut::HyperPlane, x::AbstractArray)
    bundle.q += cut(x)
end
function _add_to_bundle!(bundle::CutBundle, cut::HyperPlane{OptimalityCut}, x::AbstractArray)
    push!(bundle.cuts, cut)
    bundle.q += cut(x)
end

function calculate_subobjective(subworker::SubWorker{F,T,A,S}, x::A) where {F, T <: Real, A <: AbstractArray, S <: LQSolver}
    subproblems::Vector{SubProblem{F,T,A,S}} = fetch(subworker)
    if length(subproblems) > 0
        return sum([subproblem.π*subproblem(x) for subproblem in subproblems])
    else
        return zero(T)
    end
end

function fill_submodels!(subworker::SubWorker{F,T,A,S},
                         x::A,
                         scenarioproblems::ScenarioProblems) where {F, T <: Real, A <: AbstractArray, S <: LQSolver}
    sp = fetch(scenarioproblems)
    subproblems::Vector{SubProblem{F,T,A,S}} = fetch(subworker)
    for (i, submodel) in enumerate(sp.problems)
        subproblems[i](x)
        fill_submodel!(submodel, subproblems[i])
    end
end

function fill_submodel!(submodel::JuMP.Model, x::AbstractVector, μ::AbstractVector, λ::AbstractVector, C::Real)
    submodel.colVal = x
    submodel.redCosts = μ
    submodel.linconstrDuals = λ
    submodel.objVal = C
    submodel.objVal *= submodel.objSense == :Min ? 1 : -1
end

function fill_submodel!(submodel::JuMP.Model, subproblem::SubProblem)
    fill_submodel!(submodel, get_solution(subproblem)...)
end

function iterate_parallel!(lshaped::AbstractLShapedSolver{F,T}) where {F, T <: Real}
    wait(lshaped.cutqueue)
    while isready(lshaped.cutqueue)
        # Add new cuts from subworkers
        t::Int,Q::T,cut::SparseHyperPlane{T} = take!(lshaped.cutqueue)
        if Q == Inf && !F
            @warn "Subproblem $(cut.id) is infeasible, aborting procedure."
            return :Infeasible
        end
        if !bounded(cut)
            map((w,aw)->!isready(aw) && put!(w,-1), lshaped.work, lshaped.active_workers)
            @warn "Subproblem $(cut.id) is unbounded, aborting procedure."
            return :Unbounded
        end
        add_cut!(lshaped, cut, lshaped.subobjectives[t], Q)
        update_objective!(lshaped, cut)
        lshaped.finished[t] += 1
        if lshaped.finished[t] == nbundles(lshaped)
            lshaped.solverdata.timestamp = t
            lshaped.x[:] = fetch(lshaped.decisions, t)
            lshaped.Q_history[t] = current_objective_value(lshaped, lshaped.subobjectives[t])
            lshaped.solverdata.Q = lshaped.Q_history[t]
            lshaped.solverdata.θ = t > 1 ? lshaped.θ_history[t-1] : -1e10
            take_step!(lshaped)
            lshaped.solverdata.θ = lshaped.θ_history[t]
            # Check if optimal
            if check_optimality(lshaped)
                # Optimal, tell workers to stop
                map((w,aw)->!isready(aw) && put!(w,t), lshaped.work, lshaped.active_workers)
                map((w,aw)->!isready(aw) && put!(w,-1), lshaped.work, lshaped.active_workers)
                # Final log
                log!(lshaped, lshaped.solverdata.iterations)
                return :Optimal
            end
        end
    end
    # Resolve master
    t = lshaped.solverdata.iterations
    if lshaped.finished[t] >= lshaped.parameters.κ*nbundles(lshaped) && length(lshaped.cuts) >= nbundles(lshaped)
        try
            solve_problem!(lshaped, lshaped.mastersolver)
        catch
            # Master problem could not be solved for some reason.
            @unpack Q,θ = lshaped.solverdata
            gap = abs(θ-Q)/(abs(Q)+1e-10)
            @warn "Master problem could not be solved, solver returned status $(status(lshaped.mastersolver)). The following relative tolerance was reached: $(@sprintf("%.1e",gap)). Aborting procedure."
            map((w,aw)->!isready(aw) && put!(w,-1), lshaped.work, lshaped.active_workers)
            return :StoppedPrematurely
        end
        if status(lshaped.mastersolver) == :Infeasible
            @warn "Master is infeasible. Aborting procedure."
            map((w,aw)->!isready(aw) && put!(w,-1), lshaped.work, lshaped.active_workers)
            return :Infeasible
        end
        # Update master solution
        update_solution!(lshaped)
        θ = calculate_estimate(lshaped)
        if t > 1 && abs(θ-lshaped.θ_history[t-1]) <= 10*lshaped.parameters.τ*abs(1e-10+θ) && lshaped.finished[t] != nbundles(lshaped)
            # Not enough new information in master. Repeat iterate
            return :Valid
        end
        lshaped.solverdata.θ = θ
        lshaped.θ_history[t] = θ
        # Project (if applicable)
        project!(lshaped)
        # If all work is finished at this timestamp, check optimality
        if lshaped.finished[t] == nbundles(lshaped)
            # Check if optimal
            if check_optimality(lshaped)
                # Optimal, tell workers to stop
                map((w,aw)->!isready(aw) && put!(w,t), lshaped.work, lshaped.active_workers)
                map((w,aw)->!isready(aw) && put!(w,-1), lshaped.work, lshaped.active_workers)
                # Final log
                log!(lshaped, t)
                return :Optimal
            end
        end
        # Log progress at current timestamp
        log_regularization!(lshaped, t)
        # Send new decision vector to workers
        put!(lshaped.decisions, t+1, lshaped.x)
        map((w,aw)->!isready(aw) && put!(w,t+1), lshaped.work, lshaped.active_workers)
        # Prepare memory for next iteration
        push!(lshaped.subobjectives, zeros(nbundles(lshaped)))
        push!(lshaped.finished, 0)
        # Log progress
        log!(lshaped)
        lshaped.θ_history[t+1] = -Inf
    end
    # Just return a valid status for this iteration
    return :Valid
end
