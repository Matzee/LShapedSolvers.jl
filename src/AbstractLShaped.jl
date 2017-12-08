abstract type AbstractLShapedSolver{float_t <: Real, array_t <: AbstractVector, msolver_t <: LQSolver, ssolver_t <: LQSolver} end

nscenarios(lshaped::AbstractLShapedSolver) = lshaped.nscenarios

function Base.show(io::IO, lshaped::AbstractLShapedSolver)
    print(io,"LShapedSolver")
end

function Base.show(io::IO, ::MIME"text/plain", lshaped::AbstractLShapedSolver)
    show(io,lshaped)
end

# Initialization #
# ======================================================================== #
function init!(lshaped::AbstractLShapedSolver{float_t,array_t,msolver_t,ssolver_t},subsolver::AbstractMathProgSolver) where {float_t <: Real, array_t <: AbstractVector, msolver_t <: LQSolver, ssolver_t <: LQSolver}
    append!(lshaped.subobjectives,zeros(lshaped.nscenarios))
    append!(lshaped.θs,fill(-Inf,lshaped.nscenarios))
    # Prepare the master optimization problem
    prepare_master!(lshaped)
    # Finish initialization based on solver traits
    initSolverData!(lshaped)
    initSolver!(lshaped,subsolver)
end

# ======================================================================== #

# Functions #
# ======================================================================== #
function update_solution!(lshaped::AbstractLShapedSolver)
    ncols = lshaped.structuredmodel.numCols
    lshaped.x[1:ncols] = lshaped.mastersolver.x[1:ncols]
    lshaped.θs[:] = lshaped.mastersolver.x[end-lshaped.nscenarios+1:end]
end

function update_structuredmodel!(lshaped::AbstractLShapedSolver)
    c = JuMP.prepAffObjective(lshaped.structuredmodel)
    c *= lshaped.structuredmodel.objSense == :Min ? 1 : -1
    lshaped.structuredmodel.colVal = copy(lshaped.x)
    lshaped.structuredmodel.objVal = c⋅lshaped.x + sum(lshaped.subobjectives)
    lshaped.structuredmodel.objVal *= lshaped.structuredmodel.objSense == :Min ? 1 : -1

    for i in 1:lshaped.nscenarios
        m = getchildren(lshaped.structuredmodel)[i]
        m.colVal = copy(lshaped.subproblems[i].solver.x)
        m.objVal = copy(lshaped.subproblems[i].solver.obj)
        m.objVal *= m.objSense == :Min ? 1 : -1
    end
end

function calculate_objective_value(lshaped::AbstractLShapedSolver)
    c = JuMP.prepAffObjective(lshaped.structuredmodel)
    c *= lshaped.structuredmodel.objSense == :Min ? 1 : -1

    return c⋅lshaped.x + sum(lshaped.subobjectives)
end

function extract_master!(lshaped::AbstractLShapedSolver,src::JuMPModel)
    @assert haskey(src.ext,:Stochastic) "The provided model is not structured"

    # Minimal copy of master part of structured problem
    master = Model()

    if src.colNames[1] == ""
        for varFamily in src.dictList
            JuMP.fill_var_names(JuMP.REPLMode,src.colNames,varFamily)
        end
    end

    # Objective
    master.obj = copy(src.obj, master)
    master.objSense = src.objSense

    # Constraint
    master.linconstr  = map(c->copy(c, master), src.linconstr)

    # Variables
    master.numCols = src.numCols
    master.colNames = src.colNames[:]
    master.colNamesIJulia = src.colNamesIJulia[:]
    master.colLower = src.colLower[:]
    master.colUpper = src.colUpper[:]
    master.colCat = src.colCat[:]
    master.colVal = src.colVal[:]

    lshaped.masterModel = master
end

function prepare_master!(lshaped::AbstractLShapedSolver)
    # θs
    for i = 1:lshaped.nscenarios
        addvar!(lshaped.mastersolver.lqmodel,-Inf,Inf,1.0)
    end
    append!(lshaped.mastersolver.x,zeros(lshaped.nscenarios))
end

function resolve_subproblems!(lshaped::AbstractLShapedSolver)
    # Update subproblems
    update_subproblems!(lshaped.subproblems,lshaped.x)

    # Solve sub problems
    for subproblem ∈ lshaped.subproblems
        println("Solving subproblem: ",subproblem.id)
        cut = subproblem()
        if !bounded(cut)
            println("Subproblem ",subproblem.id," is unbounded, aborting procedure.")
            println("======================")
            return
        end
        addcut!(lshaped,cut)
    end
end
# ======================================================================== #

# Parallel routines #
# ======================================================================== #
function init_subworker(subworker::RemoteChannel,parent::JuMPModel,submodels::Vector{JuMPModel},πs::AbstractVector,ids::AbstractVector)
    subproblems = Vector{SubProblem}(length(ids))
    for (i,id) = enumerate(ids)
        subproblems[i] = SubProblem(submodels[i],parent,id,πs[i])
    end
    put!(subworker,subproblems)
end

function work_on_subproblems(subworker::RemoteChannel,cuts::RemoteChannel,rx::RemoteChannel)
    subproblems = fetch(subworker)
    while true
        wait(rx)
        x = take!(rx)
        if isempty(x)
            println("Worker finished")
            return
        end
        updateSubProblems!(subproblems,x)
        for subprob in subproblems
            println("Solving subproblem: ",subprob.id)
            put!(cuts,subprob())
            println("Subproblem: ",subprob.id," solved")
        end
    end
end

function calculate_subobjective(subworker::RemoteChannel,x::AbstractVector)
    subproblems = fetch(subworker)
    if length(subproblems) > 0
        return sum([subprob.π*subprob(x) for subprob in subproblems])
    else
        return zero(eltype(x))
    end
end

# ======================================================================== #
# TRAITS #
# ======================================================================== #
# UsesLocalization: Algorithm uses some localization method
@define_trait UsesLocalization = begin
    IsRegularized # Algorithm uses the regularized decomposition method of Ruszczyński
    HasTrustRegion # Algorithm uses the trust-region method of Linderoth/Wright
end

@define_traitfn UsesLocalization function initSolverData!(lshaped::AbstractLShapedSolver{float_t,array_t,msolver_t,ssolver_t}) where {float_t <: Real, array_t <: AbstractVector, msolver_t <: LQSolver, ssolver_t <: LQSolver}
    nothing
end

@define_traitfn UsesLocalization function check_optimality(lshaped::AbstractLShapedSolver)
    Q = sum(lshaped.subobjectives)
    θ = sum(lshaped.θs)
    return θ > -Inf && abs(θ-Q) <= lshaped.τ*(1+abs(θ))
end function check_optimality(lshaped::AbstractLShapedSolver,UsesLocalization)
    c = JuMP.prepAffObjective(lshaped.structuredmodel)
    c *= lshaped.structuredmodel.objSense == :Min ? 1 : -1
    θ = c⋅lshaped.x + sum(lshaped.θs)

    if abs(θ - lshaped.Q̃) <= lshaped.τ*(1+abs(lshaped.Q̃))
        return true
    else
        return false
    end
end

@define_traitfn UsesLocalization queueViolated!(lshaped::AbstractLShapedSolver) function queueViolated!(lshaped::AbstractLShapedSolver,UsesLocalization)
    violating = find(c->violated(lshaped,c),lshaped.inactive)
    if isempty(violating)
        return false
    end
    gaps = map(c->gap(lshaped,c),lshaped.inactive[violating])
    if isempty(lshaped.violating)
        lshaped.violating = PriorityQueue(Reverse,zip(lshaped.inactive[violating],gaps))
    else
        for (c,g) in zip(lshaped.inactive[violating],gaps)
            enqueue!(lshaped.violating,c,g)
        end
    end
    deleteat!(lshaped.inactive,violating)
    return true
end

# ------------------------------------------------------------
# IsParallel -> Algorithm is run in parallel
# ------------------------------------------------------------
@define_trait IsParallel

@define_traitfn IsParallel function initSolver!(lshaped::AbstractLShapedSolver{float_t,array_t,msolver_t,ssolver_t},subsolver::AbstractMathProgSolver) where {float_t <: Real, array_t <: AbstractVector, msolver_t <: LQSolver, ssolver_t <: LQSolver}
    # Prepare the subproblems
    m = lshaped.structuredmodel
    π = getprobability(m)
    for i = 1:lshaped.nscenarios
        x₀ = convert(array_t,rand(getchildren(m)[i].numCols))
        push!(lshaped.subproblems,SubProblem(getchildren(m)[i],m,i,π[i],copy(lshaped.x),x₀,subsolver))
    end
    lshaped
end

@implement_traitfn IsParallel function initSolver!(lshaped::AbstractLShapedSolver)
    # Workers
    lshaped.subworkers = Vector{RemoteChannel}(nworkers())
    lshaped.cutQueue = RemoteChannel(() -> Channel{Hyperplane}(4*nworkers()*lshaped.nscenarios))
    lshaped.masterColumns = Vector{RemoteChannel}(nworkers())
    (jobLength,extra) = divrem(lshaped.nscenarios,nworkers())
    # One extra to guarantee coverage
    if extra > 0
        jobLength += 1
    end

    # Create subproblems on worker processes
    start = 1
    stop = jobLength
    @sync for w in workers()
        lshaped.subworkers[w-1] = RemoteChannel(() -> Channel{Vector{SubProblem}}(1), w)
        lshaped.masterColumns[w-1] = RemoteChannel(() -> Channel{AbstractVector}(5), w)
        put!(lshaped.masterColumns[w-1],lshaped.x)
        submodels = [getchildren(m)[i] for i = start:stop]
        πs = [getprobability(lshaped.structuredModel)[i] for i = start:stop]
        @spawnat w init_subworker(lshaped.subworkers[w-1],m,submodels,πs,collect(start:stop))
        if start > lshaped.nscenarios
            continue
        end
        start += jobLength
        stop += jobLength
        stop = min(stop,lshaped.nscenarios)
    end
    lshaped
end

@define_traitfn IsParallel function calculateObjective(lshaped::AbstractLShapedSolver,x::AbstractVector)
    c = JuMP.prepAffObjective(lshaped.structuredModel)
    c *= lshaped.structuredModel.objSense == :Min ? 1 : -1
    return c⋅x + sum([subprob.π*subprob(x) for subprob in lshaped.subProblems])
end

@implement_traitfn IsParallel function calculateObjective(lshaped::AbstractLShapedSolver,x::AbstractVector)
    c = lshaped.structuredModel.obj.aff.coeffs
    c *= lshaped.structuredModel.objSense == :Min ? 1 : -1
    objidx = [v.col for v in lshaped.structuredModel.obj.aff.vars]
    return c⋅x[objidx] + sum(fetch.([@spawnat w calculate_subobjective(worker,x) for (w,worker) in enumerate(lshaped.subworkers)]))
end

# ------------------------------------------------------------------------ #

# ======================================================================== #
