% Generated by roxygen2: do not edit by hand
% Please edit documentation in R/features.R
\name{unitroot_kpss}
\alias{unitroot_kpss}
\alias{unitroot_pp}
\title{Unit root tests}
\usage{
unitroot_kpss(x, type = c("mu", "tau"), lags = c("short", "long",
  "nil"), use.lag = NULL, ...)

unitroot_pp(x, type = c("Z-tau", "Z-alpha"), model = c("constant",
  "trend"), lags = c("short", "long"), use.lag = NULL, ...)
}
\arguments{
\item{x}{A vector to be tested for the unit root.}

\item{type}{Type of deterministic part.}

\item{lags}{Maximum number of lags used for error term correction.}

\item{use.lag}{User specified number of lags.}

\item{...}{Unused.}

\item{model}{Determines the deterministic part in the test regression.}
}
\description{
Performs a test for the existence of a unit root in the vector.
}
\details{
\code{unitroot_kpss} computes the statistic for the Kwiatkowski et al. unit root test with linear trend and lag 1.

\code{unitroot_pp} computes the statistic for the `'Z-tau'' version of Phillips & Perron unit root test with constant trend and lag 1.
}
\seealso{
\code{\link[urca:ur.kpss]{urca::ur.kpss()}}

\code{\link[urca:ur.pp]{urca::ur.pp()}}
}
