# PPCA - Implementation of the Probabilistic Principal Components
# Analysis (PPCA) model.
#
# Lucas Ondel 2020

#######################################################################
# Model definition

"""
    struct PPCAModel{T,D,Q}
        trans   # Affine transform
        λ       # Precision parameter
    end

Standard PPCA model.
"""
struct PPCAModel{T,D,Q}
    trans::AffineTransform{T,D,Q}
    λ::BayesParam{Gamma{T}}
end

function PPCAModel(T::Type{<:AbstractFloat}; datadim, latentdim,
                   pstrength = 1e-3, W_MAP = false)

    trans = AffineTransform(T, outputdim = datadim, inputdim = latentdim,
                            pstrength = pstrength, W_MAP = W_MAP)
    λprior = Gamma{T}(pstrength, pstrength)
    λposterior = Gamma{T}(pstrength, pstrength)
    λ = BayesParam(λprior, λposterior)

    PPCAModel{T,datadim,latentdim}(trans, λ)
end

PPCAModel(;datadim, latentdim, pstrength = 1e-3,
          W_MAP = false) = PPCAModel(Float64;
                                         datadim = datadim,
                                         latentdim = latentdim,
                                         pstrength = pstrength,
                                         W_MAP = W_MAP)

#######################################################################
# Estimate the latent variables

function (m::PPCAModel{T,D,Q})(X::AbstractVector) where {T,D,Q}
    S₁, S₂ = hstats(m.trans, X)
    λ̄ = mean(m.λ.posterior)
    S₁, S₂ = λ̄*S₁, λ̄*S₂

    Λ₀ = inv(m.trans.hprior.Σ)
    Λ₀μ₀ = Λ₀ * m.trans.hprior.μ
    Σ = Symmetric(inv(Λ₀ + S₂))
    [Normal(Σ * (Λ₀μ₀ + mᵢ), Σ) for mᵢ in S₁]
end

#######################################################################
# Pretty print

function Base.show(io::IO, ::MIME"text/plain", model::PPCAModel)
    println(io, typeof(model), ":")
    println(io, "  trans: $(typeof(model.trans))")
    println(io, "  λ: $(typeof(model.λ))")
end

#######################################################################
# Log-likelihood

function _llh_d(::PPCAModel, x, Tŵ, Tλ, Th)
    λ, lnλ = Tλ
    h, hhᵀ = Th

    # Extract the bias parameter
    wwᵀ = Tŵ[2][1:end-1, 1:end-1]
    w = Tŵ[1][1:end-1]
    μ = Tŵ[1][end]
    μ² = Tŵ[2][end, end]

    x̄ = dot(w, h) + μ
    lognorm = (-log(2π) + lnλ - λ*(x^2))/2
    K = λ*(x̄*x - dot(w, h)*μ - (dot(vec(hhᵀ), vec(wwᵀ)) + μ²)/2)

    lognorm + K
end

function _llh(m::PPCAModel, x, Tŵs, Tλ, Th)
    f = (a,b) -> begin
        xᵢ, Tŵᵢ = b
        a + _llh_d(m, xᵢ, Tŵᵢ, Tλ, Th)
    end
    foldl(f, zip(x, Tŵs), init = 0)
end

function loglikelihood(m::PPCAModel{T,D,Q}, X) where {T,D,Q}
    hposts = X |> m
    _llh.(
        [m],
        X,
        [[gradlognorm(w.posterior, vectorize = false) for w in m.trans.W ]],
        [gradlognorm(m.λ.posterior, vectorize = false)],
        [gradlognorm(p, vectorize = false) for p in hposts]
   ) - kldiv.(hposts, [m.trans.hprior])
end

#######################################################################
# Update of the precision parameter λ

function _λstats_d(::PPCAModel, x::Real, Tŵ, Th)
    h, hhᵀ = Th

    # Extract the bias parameter
    w = Tŵ[1][1:end-1]
    wwᵀ = Tŵ[2][1:end-1, 1:end-1]
    μ = Tŵ[1][end]
    μ² = Tŵ[2][end, end]

    x̄ = dot(w, h) + μ
    Tλ₁ = -.5*x^2 + x*x̄ - dot(w, h)*μ - .5*(dot(vec(hhᵀ), vec(wwᵀ)) + μ²)
    Tλ₂ = 1/2
    vcat(Tλ₁, Tλ₂)
end

function _λstats(m::PPCAModel, x::AbstractVector, Tŵ, Th)
    sum(_λstats_d.([m], x, Tŵ, [Th]))
end

function λstats(m::PPCAModel, X, hposts)
    Tŵ = [gradlognorm(w.posterior, vectorize = false) for w in m.trans.W]
    Th = [gradlognorm(p, vectorize = false) for p in hposts]
    sum(_λstats.([m], X, [Tŵ], Th))
end

function update_λ!(m::PPCAModel, accstats)::Nothing
    η₀ = naturalparam(m.λ.prior)
    update!(m.λ.posterior, η₀ + accstats)
    nothing
end


#######################################################################
# Update of the bases W

function wstats(m::PPCAModel, X, hposts)
    λ, _ = gradlognorm(m.λ.posterior, vectorize = false)
    S₁, S₂ = wstats(m.trans, X, hposts)
    [λ*S₁, λ*S₂]
end

update_W!(m::PPCAModel, accstats) = update_W!(m.trans, accstats)

#######################################################################
# Training

"""
    fit!(model, dataloader, [, epochs = 1, callback = x -> x])

Fit a PPCA model to a data set by estimating the variational posteriors
over the parameters.
"""
function fit!(model::PPCAModel, dataloader; epochs = 1, callback = x -> x)

    @everywhere dataloader = $dataloader

    # NOTE: By 1 epoch we mean TWO passes over the data, one pass to
    # update the bases and the other to update the precision parameter

    for e in 1:epochs
        # Propagate the model to all the workers
        @everywhere model = $model

        ###############################################################
        # Step 1: update the posterior of the bases
        waccstats = @distributed (+) for X in dataloader
            # E-step: estimate the posterior of the embeddings
            hposts = X |> model

            # Accumulate statistics for the bases w
            wstats(model, X, hposts)
        end
        update_W!(model, waccstats)

        # Propagate the model to all the workers
        @everywhere model = $model

        ###############################################################
        # Step 2: update the posterior of the precision λ
        λaccstats = @distributed (+) for X in dataloader
            # E-step: estimate the posterior of the embeddings
            hposts = X |> model

            # Accumulate statistics for λ
            λstats(model, X, hposts)
        end

        # M-step 2: update the posterior of the precision parameter λ
        update_λ!(model, λaccstats)

        # Notify the caller
        callback(e)
    end
end

