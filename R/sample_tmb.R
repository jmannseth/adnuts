## Copyright (C) 2015 Cole Monnahan
## License: GPL-2

#' [BETA VERSION] Draw samples from the posterior of a TMB model using a
#' specified MCMC algorithm.
#'
#' @details This function is a top-level wrapper designed specifically to
#'   work with TMB models. There are several MCMC algorithms available for
#'   use. The user is responsible for specifying the model properly
#'   (priors, starting values, desired parameters fixed, etc.), as well as
#'   assessing the convergence and validity of the resulting samples (e.g.,
#'   through the \code{coda} package) before making inference.
#' @title MCMC sampling of TMB models
#' @author Cole Monnahan
#' @param obj A TMB model object.
#' @param iter The number of (dependent) samples to draw.
#' @param init A list of lists containing the initial parameter vectors,
#'   one for each chain. It is strongly recommended to initialize multiple
#'   chains from dispersed points. The default of NULL signifies to use the
#'   starting values present in the model (i.e., \code{obj$par}), but this
#'   will apply to all chains.
#' @param covar An optional covariance matrix which can be used to improve
#'   the efficiency of sampling. The lower Cholesky decomposition of this
#'   matrix is used to transform the parameter space. If the posterior is
#'   approximately multivariate normal and \code{covar} approximates the
#'   covariance, then the transformed parameter space will be close to
#'   multivariate standard normal. In this case the algorithm will be more
#'   efficient, but there will be overhead in the matrix calculations which
#'   need to be done at each step. The default of NULL specifies to not do
#'   this transformation.
#' @param algorithm A string specifiying an algorithm. Currently supported
#'   are: \itemize{ \item{"RWM"}{the random walk Metropolis sampler}
#'   \item{"HMC"}{the Hamiltonian sampler (see Neal 2011)}
#'   \item{"NUTS"}{the No-U-Turn sampler (see Hoffman and Gelman 2014)} }
#'   These algorithms require different arguments; see their help files for
#'   more information.
#' @param thin The thinning rate to apply to samples. The default of 1
#'   means to not thin (keep all samples). Thinning usually is not
#'   necessary for NUTS but in some cases may be useful.
#' @param ... Further arguments to be passed to the algorithm. See help
#'   files for the samplers for further arguments.
#' @return A list containing the samples and properties of the sampler
#'   useful for diagnosing behavior and efficiency.
#' @seealso \code{\link{run_mcmc.hmc}}, \code{\link{run_mcmc.nuts}},
#'   \code{\link{run_mcmc.rwm}}
#' @export
sample_tmb <- function(obj, iter, algorithm="NUTS", chains=1, init=NULL,
                     covar=NULL, lower=NULL, upper=NULL, thin=1, ...){
  ## Argument checking
  if(is.null(init)){
    if(chains>1) warning('Using same inits for each chain -- strongly recommended to use dispersed inits')
    init <- rep(list(obj$par), times=chains)
  } else if(is.function(init)){
    init <- lapply(1:chains, function(i) unlist(init()))
  } else if(length(init) != chains){
    stop("Length of init does not equal number of chains.")
  } else if(any(unlist(lapply(init, function(x) length(x) != length(obj$par))))){
    stop("Initial parameter vector is wrong length")
  }
  algorithm <- match.arg(algorithm, choices=c("NUTS", "RWM", "HMC"))
  thin <- floor(thin)
  stopifnot(thin >=1)
  stopifnot(chains >= 1)
  if(iter < 10 | !is.numeric(iter)) stop("iter must be > 10")
  obj$env$beSilent()                  # silence console output

  ## Parameter constraints, if provided, require the fn and gr functions to
  ## be modified to account for differents in volume. There are four cases:
  ## no constraints, bounded below, bounded above, or both (box
  ## constraint).
  bounded <- !(is.null(lower) & is.null(upper))
  if(bounded){
    if(is.null(lower)) lower <- rep(-Inf, len=length(upper))
    if(is.null(upper)) upper <- rep(Inf, len=length(lower))
    cases <- .transform.cases(lower, upper)
    fn <- function(y){
      x <- .transform(y, lower, upper, cases)
      scales <- .transform.grad(y, lower, upper, cases)
      -obj$fn(x) + sum(log(scales))
    }
    gr <- function(y){
      x <- .transform(y, lower, upper, cases)
      scales <- .transform.grad(y, lower, upper, cases)
      scales2 <- .transform.grad2(y, lower, upper, cases)
      -as.vector(obj$gr(x))*scales + scales2
    }
    init <- lapply(init, FUN=.transform.inv, a=lower, b=upper, cases=cases)
  } else {
    fn <- function(x) -obj$fn(x)
    gr <- function(x) -as.vector(obj$gr(x))
  }

  ## Make parameter names unique if vectors exist
  par.names <- names(obj$par)
  par.names <- as.vector((unlist(sapply(unique(par.names), function(x){
    temp <- par.names[par.names==x]
    if(length(temp)>1) paste0(temp,'[',1:length(temp),']') else temp
    }))))

  ## Select and run the chain.
  if(algorithm=="HMC"){
    mcmc.out <- lapply(1:chains, function(i)
      run_mcmc.hmc(iter=iter, fn=fn, gr=gr, init=init[[i]],
                   covar=covar, chain=i, thin=thin, ...))
  } else if(algorithm=="NUTS"){
    mcmc.out <- lapply(1:chains, function(i)
      run_mcmc.nuts(iter=iter, fn=fn, gr=gr, init=init[[i]],
                    covar=covar, chain=i, thin=thin, ...))
  } else if(algorithm=="RWM")
    mcmc.out <- lapply(1:chains, function(i)
      run_mcmc.rwm(iter=iter, fn=fn, init=init[[i]], covar=covar,
                  thin=thin, ...))

  ## Clean up returned output
  samples <-  array(NA, dim=c(nrow(mcmc.out[[1]]$par), chains, 1+length(par.names)),
                    dimnames=list(NULL, NULL, c(par.names,'lp__')))
  for(i in 1:chains){
    if(bounded){
      temp <- mcmc.out[[i]]$par
      temp[,-ncol(temp)] <-
        t(apply(temp[,-ncol(temp)], 1, function(x)
          .transform(x, lower, upper, cases)))
      samples[,i,] <- temp
    } else {
      samples[,i,] <- mcmc.out[[i]]$par
    }
  }
  sampler_params <- lapply(mcmc.out, function(x) x$sampler_params)
  time.warmup <- unlist(lapply(mcmc.out, function(x) as.numeric(x$time.warmup)))
  time.total <- unlist(lapply(mcmc.out, function(x) as.numeric(x$time.total)))
  result <- list(samples=samples, sampler_params=sampler_params,
                 time.warmup=time.warmup, time.total=time.total,
                 algorithm=algorithm, warmup=mcmc.out[[1]]$warmup,
                 model=obj$env$DLL)
  if(algorithm=="NUTS") result$max_treedepth <- mcmc.out[[1]]$max_treedepth
  return(invisible(result))
}

