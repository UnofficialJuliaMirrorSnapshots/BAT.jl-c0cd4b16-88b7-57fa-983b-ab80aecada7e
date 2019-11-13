# This file is a part of BAT.jl, licensed under the MIT License (MIT).


# ToDo: Add literature references to AdaptiveMetropolisTuning docstring.

"""
    AdaptiveMetropolisTuning(...)

Ajusts the proposal function based on the acceptance ratio and covariance
of the previous samples.
"""
@with_kw struct AdaptiveMetropolisTuning <: AbstractMCMCTunerConfig
    λ::Float64 = 0.5
    α::IntervalSets.ClosedInterval{Float64} = ClosedInterval(0.15, 0.35)
    β::Float64 = 1.5
    c::IntervalSets.ClosedInterval{Float64} = ClosedInterval(1e-4, 1e2)
end

export AdaptiveMetropolisTuning


# Deprecate:
AbstractMCMCTunerConfig(algorithm::MetropolisHastings) = AdaptiveMetropolisTuning()

(config::AdaptiveMetropolisTuning)(chain::MHIterator) = ProposalCovTuner(config, chain)



mutable struct ProposalCovTuner{
    S<:MCMCBasicStats
} <: AbstractMCMCTuner
    config::AdaptiveMetropolisTuning
    stats::S
    iteration::Int
    scale::Float64
end

export ProposalCovTuner

function ProposalCovTuner(
    config::AdaptiveMetropolisTuning,
    chain::MHIterator
)
    m = nparams(chain)
    scale = 2.38^2 / m
    ProposalCovTuner(config, MCMCBasicStats(chain), 1, scale)
end


isviable(tuner::ProposalCovTuner, chain::MHIterator) = nsamples(chain) >= 2


function tuning_init!(tuner::ProposalCovTuner, chain::MHIterator)
    Σ_unscaled = cov(getprior(getposterior(chain)))
    Σ = Σ_unscaled * tuner.scale

    next_cycle!(chain)
    chain.proposaldist = set_cov(chain.proposaldist, Σ)

    nothing
end


function tuning_update!(tuner::ProposalCovTuner, chain::MHIterator)
    config = tuner.config

    α_min = minimum(config.α)
    α_max = maximum(config.α)

    c_min = minimum(config.c)
    c_max = maximum(config.c)

    β = config.β

    t = tuner.iteration
    λ = config.λ
    c = tuner.scale
    Σ_old = Matrix(get_cov(chain.proposaldist))

    S = convert(Array, tuner.stats.param_stats.cov)
    a_t = 1 / t^λ
    new_Σ_unscal = (1 - a_t) * (Σ_old/c) + a_t * S

    α = eff_acceptance_ratio(chain)

    if α_min <= α <= α_max
        chain.info = MCMCIteratorInfo(chain.info, tuned = true)
        @debug "MCMC chain $(chain.info.id) tuned, acceptance ratio = $α"
    else
        chain.info = MCMCIteratorInfo(chain.info, tuned = false)
        @debug "MCMC chain $(chain.info.id) *not* tuned, acceptance ratio = $α"

        if α > α_max && c < c_max
            tuner.scale = c * β
        elseif α < α_min && c > c_min
            tuner.scale = c / β
        end
    end

    Σ_new_raw = new_Σ_unscal * tuner.scale
    Σ_new = PDMat(cholesky(Positive, Hermitian(Σ_new_raw)))

    next_cycle!(chain)
    chain.proposaldist = set_cov(chain.proposaldist, Σ_new)
    tuner.iteration += 1

    nothing
end


function run_tuning_cycle!(
    callbacks,
    tuners::AbstractVector{<:ProposalCovTuner},
    chains::AbstractVector{<:MHIterator};
    kwargs...
)
    run_tuning_iterations!(callbacks, tuners, chains; kwargs...)
    tuning_update!.(tuners, chains)
    nothing
end


function run_tuning_iterations!(
    callbacks,
    tuners::AbstractVector{<:ProposalCovTuner},
    chains::AbstractVector{<:MHIterator};
    max_nsamples::Int64 = Int64(1000),
    max_nsteps::Int64 = Int64(10000),
    max_time::Float64 = Inf
)
    user_callbacks = mcmc_callback_vector(callbacks, eachindex(chains))

    combined_callbacks = broadcast(tuners, user_callbacks) do tuner, user_callback
        (level, chain) -> begin
            if level == 1
                get_samples!(tuner.stats, chain, true)
            end
            user_callback(level, chain)
        end
    end

    mcmc_iterate!(combined_callbacks, chains, max_nsamples = max_nsamples, max_nsteps = max_nsteps, max_time = max_time)
    nothing
end
