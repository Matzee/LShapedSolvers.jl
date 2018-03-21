@with_kw mutable struct LShapedData{T <: Real}
    Q::T = 1e10
    θ::T = -1e10
    iterations::Int = 0
end

@with_kw struct LShapedParameters{T <: Real}
    τ::T = 1e-6
end

struct LShaped{T <: Real, A <: AbstractVector, M <: LQSolver, S <: LQSolver} <: AbstractLShapedSolver{T,A,M,S}
    structuredmodel::JuMP.Model
    solverdata::LShapedData{T}

    # Master
    mastersolver::M
    c::A
    x::A
    Q_history::A

    # Subproblems
    nscenarios::Int
    subproblems::Vector{SubProblem{T,A,S}}
    subobjectives::A

    # Cuts
    θs::A
    cuts::Vector{SparseHyperPlane{T}}
    θ_history::A

    # Params
    parameters::LShapedParameters{T}

    function (::Type{LShaped})(model::JuMP.Model,x₀::AbstractVector,mastersolver::AbstractMathProgSolver,subsolver::AbstractMathProgSolver; kw...)
        length(x₀) != model.numCols && error("Incorrect length of starting guess, has ",length(x₀)," should be ",model.numCols)
        !haskey(model.ext,:SP) && error("The provided model is not structured")

        T = promote_type(eltype(x₀),Float32)
        c_ = convert(AbstractVector{T},JuMP.prepAffObjective(model))
        c_ *= model.objSense == :Min ? 1 : -1
        x₀_ = convert(AbstractVector{T},copy(x₀))
        A = typeof(x₀_)

        msolver = LQSolver(model,mastersolver)
        M = typeof(msolver)
        S = LQSolver{typeof(LinearQuadraticModel(subsolver)),typeof(subsolver)}
        n = StochasticPrograms.nscenarios(model)

        lshaped = new{T,A,M,S}(model,
                               LShapedData{T}(),
                               msolver,
                               c_,
                               x₀_,
                               A(),
                               n,
                               Vector{SubProblem{T,A,S}}(),
                               A(zeros(n)),
                               A(fill(-1e10,n)),
                               Vector{SparseHyperPlane{T}}(),
                               A(),
                               LShapedParameters{T}(;kw...))
        init!(lshaped,subsolver)

        return lshaped
    end
end
LShaped(model::JuMP.Model,mastersolver::AbstractMathProgSolver,subsolver::AbstractMathProgSolver; kw...) = LShaped(model,rand(model.numCols),mastersolver,subsolver; kw...)

function (lshaped::LShaped)()
    println("Starting L-Shaped procedure")
    println("======================")

    println("Main loop")
    println("======================")

    while true
        iterate!(lshaped)

        if check_optimality(lshaped)
            # Optimal
            lshaped.solverdata.Q = calculateObjective(lshaped,lshaped.x)
            push!(lshaped.Q_history,lshaped.solverdata.Q)
            println("Optimal!")
            println("Objective value: ", calculate_objective_value(lshaped))
            println("======================")
            break
        end
    end
end

function (lshaped::LShaped)(timer::TimerOutput)
    println("Starting L-Shaped procedure")
    println("======================")

    println("Main loop")
    println("======================")

    while true
        @timeit timer "Iterate" iterate!(lshaped,timer)

        @timeit timer "Check optimality" if check_optimality(lshaped)
            # Optimal
            update_structuredmodel!(lshaped)
            println("Optimal!")
            println("Objective value: ", calculate_objective_value(lshaped))
            println("======================")
            break
        end
    end
end

function iterate!(lshaped::LShaped)
    # Resolve all subproblems at the current optimal solution
    Q = resolve_subproblems!(lshaped)
    push!(lshaped.Q_history,Q)

    # Resolve master
    println("Solving master problem")
    lshaped.mastersolver(lshaped.x)
    if status(lshaped.mastersolver) == :Infeasible
        println("Master is infeasible, aborting procedure.")
        println("======================")
        return
    end
    # Update master solution
    update_solution!(lshaped)
    θ = calculate_estimate(lshaped)
    push!(lshaped.θ_history,θ)
    @pack lshaped.solverdata = Q,θ
    lshaped.solverdata.iterations += 1
    nothing
end

function iterate!(lshaped::LShaped,timer::TimerOutput)
    # Resolve all subproblems at the current optimal solution
    @timeit timer "Subproblems" Q = resolve_subproblems!(lshaped,timer)
    push!(lshaped.Q_history,Q)

    # Resolve master
    println("Solving master problem")
    @timeit timer "Master" lshaped.mastersolver(lshaped.x)
    if status(lshaped.mastersolver) == :Infeasible
        println("Master is infeasible, aborting procedure.")
        println("======================")
        return
    end
    # Update master solution
    update_solution!(lshaped)
    push!(lshaped.θ_history,calculate_estimate(lshaped))
    nothing
end