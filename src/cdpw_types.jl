abstract type AlphaSchedule end
struct ConstantAlphaSchedule <: AlphaSchedule 
    scale::Float32
end
ConstantAlphaSchedule() = ConstantAlphaSchedule(1.e-3)
alpha(sched::ConstantAlphaSchedule, ::Int) = sched.scale

struct InverseAlphaSchedule <: AlphaSchedule 
    scale::Float32
end
InverseAlphaSchedule() = InverseAlphaSchedule(1.)
alpha(sched::InverseAlphaSchedule, query::Int) = sched.scale/query

"""
CMCTS solver with DPW

Fields:

    depth::Int64
        Maximum rollout horizon and tree depth.
        default: 10

    exploration_constant::Float64
        Specified how much the solver should explore.
        In the UCB equation, Q + c*sqrt(log(t/N)), c is the exploration constant.
        default: 1.0

    n_iterations::Int64
        Number of iterations during each action() call.
        default: 100

    max_time::Float64
        Maximum amount of CPU time spent iterating through simulations.
        default: Inf

    k_action::Float64
    alpha_action::Float64
    k_state::Float64
    alpha_state::Float64
        These constants control the double progressive widening. A new state
        or action will be added if the number of children is less than or equal to kN^alpha.
        defaults: k:10, alpha:0.5

    keep_tree::Bool
        If true, store the tree in the planner for reuse at the next timestep (and every time it is used in the future). There is a computational cost for maintaining the state dictionary necessary for this.
        default: false

    enable_action_pw::Bool
        If true, enable progressive widening on the action space; if false just use the whole action space.
        default: true

    enable_state_pw::Bool
        If true, enable progressive widening on the state space; if false just use the single next state (for deterministic problems).
        default: true

    check_repeat_state::Bool
    check_repeat_action::Bool
        When constructing the tree, check whether a state or action has been seen before (there is a computational cost to maintaining the dictionaries necessary for this)
        default: true

    tree_in_info::Bool
        If true, return the tree in the info dict when action_info is called. False by default because it can use a lot of memory if histories are being saved.
        default: false

    rng::AbstractRNG
        Random number generator

    estimate_value::Any (rollout policy)
        Function, object, or number used to estimate the value at the leaf nodes.
        If this is a function `f`, `f(mdp, s, depth)` will be called to estimate the value (depth can be ignored).
        If this is an object `o`, `estimate_value(o, mdp, s, depth)` will be called.
        If this is a number, the value will be set to that number.
        default: RolloutEstimator(RandomSolver(rng))

    init_Q::Any
        Function, object, or number used to set the initial Q(s,a) value at a new node.
        If this is a function `f`, `f(mdp, s, a)` will be called to set the value.
        If this is an object `o`, `init_Q(o, mdp, s, a)` will be called.
        If this is a number, Q will always be set to that number.
        default: 0.0

    init_N::Any
        Function, object, or number used to set the initial N(s,a) value at a new node.
        If this is a function `f`, `f(mdp, s, a)` will be called to set the value.
        If this is an object `o`, `init_N(o, mdp, s, a)` will be called.
        If this is a number, N will always be set to that number.
        default: 0

    next_action::Any
        Function or object used to choose the next action to be considered for progressive widening.
        The next action is determined based on the MDP, the state, `s`, and the current `DPWStateNode`, `snode`.
        If this is a function `f`, `f(mdp, s, snode)` will be called to set the value.
        If this is an object `o`, `next_action(o, mdp, s, snode)` will be called.
        default: RandomActionGenerator(rng)

    default_action::Any
        Function, action, or Policy used to determine the action if POMCP fails with exception `ex`.
        If this is a Function `f`, `f(pomdp, belief, ex)` will be called.
        If this is a Policy `p`, `action(p, belief)` will be called.
        If it is an object `a`, `default_action(a, pomdp, belief, ex)` will be called, and if this method is not implemented, `a` will be returned directly.
        default: `ExceptionRethrow()`

    reset_callback::Function
        Function used to reset/reinitialize the MDP to a given state `s`.
        Useful when the simulator state is not truly separate from the MDP state.
        `f(mdp, s)` will be called.
        default: `(mdp, s)->false` (optimized out)

    show_progress::Bool
        Show progress bar during simulation.
        default: false

    timer::Function:
        Timekeeping method. Search iterations ended when `timer() - start_time ≥ max_time`.
"""
@with_kw mutable struct CDPWSolver <: AbstractCMCTSSolver
    depth::Int=10
    exploration_constant::Float64=1.0
    nu::Float64=0.01
    n_iterations::Int=100
    max_time::Float64=Inf
    k_action::Float64=10.0
    alpha_action::Float64=0.5
    k_state::Float64=10.0
    alpha_state::Float64=0.5
    keep_tree::Bool=false
    enable_action_pw::Bool=true
    enable_state_pw::Bool=true
    check_repeat_state::Bool=true
    check_repeat_action::Bool=true
    return_safe_action::Bool = false
    tree_in_info::Bool=false
    search_progress_info::Bool=false
    return_best_cost::Bool=false
    rng::AbstractRNG=Random.GLOBAL_RNG
    alpha_schedule::AlphaSchedule = InverseAlphaSchedule()
    estimate_value::Any=RolloutEstimator(RandomSolver(rng))
    init_Q::Any = 0.0
    init_N::Any = 0
    init_Qc::Any = 0.
    init_λ::Union{Nothing,Vector{Float64}}=nothing
    max_clip::Union{Float64,Vector{Float64}}=Inf
    next_action::Any = RandomActionGenerator(rng)
    default_action::Any = ExceptionRethrow()
    reset_callback::Function = (mdp, s) -> false
    show_progress::Bool = false
    timer = () -> 1e-9 * time_ns()
end

mutable struct CDPWTree{S,A}
    # for each state node
    total_n::Vector{Int}
    children::Vector{Vector{Int}}
    s_labels::Vector{S}
    s_lookup::Dict{S, Int}

    # for each state-action node
    n::Vector{Int}
    q::Vector{Float64}
    qc::Vector{Vector{Float64}}
    transitions::Vector{Vector{Tuple{Int,Float64,Vector{Float64}}}}
    a_labels::Vector{A}
    a_lookup::Dict{Tuple{Int,A}, Int}

    # for tracking transitions
    n_a_children::Vector{Int}
    unique_transitions::Set{Tuple{Int,Int}}

    # constraints
    top_level_costs::Dict{Int,Vector{Float64}}


    function CDPWTree{S,A}(sz::Int=1000) where {S,A} 
        sz = min(sz, 100_000)
        return new(sizehint!(Int[], sz),
                   sizehint!(Vector{Int}[], sz),
                   sizehint!(S[], sz),
                   Dict{S, Int}(),
                   
                   sizehint!(Int[], sz),
                   sizehint!(Float64[], sz),
                   sizehint!(Vector{Vector{Float64}}[], sz), #qc
                   sizehint!(Vector{Tuple{Int,Float64,Vector{Float64}}}[], sz),
                   sizehint!(A[], sz),
                   Dict{Tuple{Int,A}, Int}(),

                   sizehint!(Int[], sz),
                   Set{Tuple{Int,Int}}(),
                   Dict{Int,Vector{Float64}}(), #top_level_costs
                  )
    end
end


function insert_state_node!(tree::CDPWTree{S,A}, s::S, maintain_s_lookup=true) where {S,A}
    push!(tree.total_n, 0)
    push!(tree.children, Int[])
    push!(tree.s_labels, s)
    snode = length(tree.total_n)
    if maintain_s_lookup
        tree.s_lookup[s] = snode
    end
    return snode
end


function insert_action_node!(tree::CDPWTree{S,A}, snode::Int, a::A, n0::Int, q0::Float64, qc0::Vector{Float64}, maintain_a_lookup=true) where {S,A}
    push!(tree.n, n0)
    push!(tree.q, q0)
    push!(tree.qc, qc0)
    push!(tree.a_labels, a)
    push!(tree.transitions, Vector{Tuple{Int,Float64,Vector{Float64}}}[])
    sanode = length(tree.n)
    push!(tree.children[snode], sanode)
    push!(tree.n_a_children, 0)

    if maintain_a_lookup
        tree.a_lookup[(snode, a)] = sanode
    end
    return sanode
end

Base.isempty(tree::CDPWTree) = isempty(tree.n) && isempty(tree.q)

struct CDPWStateNode{S,A} <: AbstractStateNode
    tree::CDPWTree{S,A}
    index::Int
end

children(n::CDPWStateNode) = n.tree.children[n.index]
n_children(n::CDPWStateNode) = length(children(n))
isroot(n::CDPWStateNode) = n.index == 1


mutable struct CDPWPlanner{P<:Union{MDP,POMDP}, S, A, SE, NA, RCB, RNG} <: AbstractCMCTSPlanner{P}
    solver::CDPWSolver
    mdp::P
    tree::Union{Nothing, CDPWTree{S,A}}
    solved_estimate::SE
    next_action::NA
    reset_callback::RCB
    rng::RNG
    budget::Vector{Float64} # remaining budget for constraint search
    _cost_mem::Union{Nothing,Vector{Float64}}   # estimate for one-step cost
    _lambda::Union{Nothing,Vector{Float64}}    # weights for dual ascent
end


function CDPWPlanner(solver::CDPWSolver, mdp::P) where P<:Union{POMDP,MDP}
    se = convert_estimator(solver.estimate_value, solver, mdp)
    return CDPWPlanner{P,
                      statetype(P),
                      actiontype(P),
                      typeof(se),
                      typeof(solver.next_action),
                      typeof(solver.reset_callback),
                      typeof(solver.rng)}(solver,
                                          mdp,
                                          nothing,
                                          se,
                                          solver.next_action,
                                          solver.reset_callback,
                                          solver.rng,
                                          costs_limit(mdp),
                                          nothing, 
                                          nothing, 
                     )
end

Random.seed!(p::CDPWPlanner, seed) = Random.seed!(p.rng, seed)
POMDPs.solve(solver::CDPWSolver, mdp::Union{POMDP,MDP}) = CDPWPlanner(solver, mdp)
