tbl_features <- function(features){
  function(...){
    list(as_tibble(squash(map(features, function(.fn, ...) as.list(.fn(...)), ...))))
  }
}

#' Extract features from a dataset
#'
#' @param .tbl A dataset
#' @param .var,.vars The variable(s) to compute features on
#' @param features A list of functions (or lambda expressions) for the features to compute.
#' @param .predicate A predicate function (or lambda expression) to be applied to the columns or a logical vector. The variables for which .predicate is or returns TRUE are selected.
#' @param ... Additional arguments to be passed to each feature.
#'
#' @export
features <- function(.tbl, .var, features, ...){
  UseMethod("features")
}

#' @export
features.tbl_ts <- function(.tbl, .var = NULL, features = list(), ...){
  dots <- dots_list(...)

  if(is_function(features)){
    features <- list(features)
  }
  features <- map(squash(features), rlang::as_function)

  .var <- enquo(.var)
  if(quo_is_null(.var)){
    inform(sprintf(
      "Feature variable not specified, automatically selected `.var = %s`",
      measured_vars(.tbl)[1]
    ))
    .var <- as_quosure(syms(measured_vars(.tbl)[[1]]), env = empty_env())
  }
  else if(possibly(compose(is_quosures, eval_tidy), FALSE)(.var)){
    abort("`features()` only supports a single variable. To compute features across multiple variables consider scoped variants like `features_at()`")
  }

  if(is.null(dots$.period)){
    dots$.period <- get_frequencies(NULL, .tbl, .auto = "smallest")
  }

  as_tibble(.tbl) %>%
    group_by(!!!key(.tbl), !!!dplyr::groups(.tbl)) %>%
    dplyr::summarise(
      .funs = tbl_features(features)(!!.var, !!!dots),
    ) %>%
    unnest(!!sym(".funs")) %>%
    dplyr::ungroup()
}

#' @rdname features
#' @export
features_at <- function(.tbl, .vars, features, ...){
  UseMethod("features_at")
}

#' @export
features_at.tbl_ts <- function(.tbl, .vars = NULL, features = list(), ...){
  dots <- dots_list(...)

  if(is_function(features)){
    features <- list(features)
  }
  features <- map(squash(features), rlang::as_function)

  quo_vars <- enquo(.vars)
  if(quo_is_null(quo_vars)){
    inform(sprintf(
      "Feature variable not specified, automatically selected `.vars = %s`",
      measured_vars(.tbl)[1]
    ))
    .vars <- as_quosures(syms(measured_vars(.tbl)[1]), env = empty_env())
  }
  else if(!possibly(compose(is_quosures, eval_tidy), FALSE)(.vars)){
    .vars <- new_quosures(list(quo_vars))
  }

  if(is.null(dots$.period)){
    dots$.period <- get_frequencies(NULL, .tbl, .auto = "smallest")
  }

  as_tibble(.tbl) %>%
    group_by(!!!key(.tbl), !!!dplyr::groups(.tbl)) %>%
    dplyr::summarise_at(
      .vars = .vars,
      .funs = tbl_features(features),
      !!!dots
    ) %>%
    unnest(!!!.vars, .sep = "_") %>%
    dplyr::ungroup()
}

#' @rdname features
#' @export
features_all <- function(.tbl, features, ...){
  UseMethod("features_all")
}

#' @export
features_all.tbl_ts <- function(.tbl, features = list(), ...){
  features_at(.tbl, .vars = as_quosures(syms(measured_vars(.tbl)), empty_env()),
              features = features, ...)
}

#' @rdname features
#' @export
features_if <- function(.tbl, .predicate, features, ...){
  UseMethod("features_if")
}

#' @export
features_if.tbl_ts <- function(.tbl, .predicate, features = list(), ...){
  mv_if <- map_lgl(.tbl[measured_vars(.tbl)], rlang::as_function(.predicate))
  features_at(.tbl,
              .vars = as_quosures(syms(measured_vars(.tbl)[mv_if]), empty_env()),
              features = features, ...)
}

#' @inherit tsfeatures::crossing_points
#' @importFrom stats median
#' @export
crossing_points <- function(x)
{
  midline <- median(x, na.rm = TRUE)
  ab <- x <= midline
  lenx <- length(x)
  p1 <- ab[1:(lenx - 1)]
  p2 <- ab[2:lenx]
  cross <- (p1 & !p2) | (p2 & !p1)
  c(crossing_points = sum(cross, na.rm = TRUE))
}

#' @inherit tsfeatures::arch_stat
#' @importFrom stats lm embed
#' @export
arch_stat <- function(x, lags = 12, demean = TRUE)
{
  if (length(x) <= 13) {
    return(c(arch_lm = NA_real_))
  }
  if (demean) {
    x <- x - mean(x, na.rm = TRUE)
  }
  mat <- embed(x^2, lags + 1)
  fit <- try(lm(mat[, 1] ~ mat[, -1]), silent = TRUE)
  if ("try-error" %in% class(fit)) {
    return(c(arch_lm = NA_real_))
  }
  arch.lm <- summary(fit)
  c(arch_lm = arch.lm$r.squared)
}

#' STL features
#'
#' Computes a variety of measures extracted from an STL decomposition of the
#' time series. This includes details about the strength of trend and seasonality.
#'
#' @param x A vector to extract features from.
#' @param .period The period of the seasonality.
#' @param s.window The seasonal window of the data (passed to [`stats::stl()`])
#' @param ... Further arguments passed to [`stats::stl()`]
#'
#' @seealso
#' [Forecasting Principle and Practices: Measuring strength of trend and seasonality](https://otexts.com/fpp3/seasonal-strength.html)
#'
#' @importFrom stats var coef
#' @export
stl_features <- function(x, .period, s.window = 13, ...){
  dots <- dots_list(...)
  dots <- dots[names(dots) %in% names(formals(stats::stl))]
  season.args <- list2(!!(names(.period)%||%as.character(.period)) :=
                         list(period = .period, s.window = s.window))
  dcmp <- eval_tidy(quo(estimate_stl(x, trend.args = list(),
                    season.args = season.args, lowpass.args = list(), !!!dots)))
  trend <- dcmp[["trend"]]
  remainder <- dcmp[["remainder"]]
  seas_adjust <- dcmp[["seas_adjust"]]
  seasonalities <- dcmp[seq_len(length(dcmp) - 3) + 1]
  names(seasonalities) <- sub("season_", "", names(seasonalities))

  var_e <- var(remainder, na.rm = TRUE)
  n <- length(x)

  # Spike
  d <- (remainder - mean(remainder, na.rm = TRUE))^2
  var_loo <- (var_e * (n - 1) - d)/(n - 2)
  spike <- var(var_loo, na.rm = TRUE)

  # Linearity & curvature
  tren.coef <- coef(lm(trend ~ poly(seq(n), degree = 2L)))[2L:3L]
  linearity <- tren.coef[[1L]]
  curvature <- tren.coef[[2L]]

  # Strength of terms
  trend_strength <- max(0, min(1, 1 - var_e/var(seas_adjust, na.rm = TRUE)))
  seasonal_strength <- map_dbl(seasonalities, function(seas){
    max(0, min(1, 1 - var_e/var(remainder + seas, na.rm = TRUE)))
  })

  # Position of peaks and troughs
  seasonal_peak <- map_dbl(seasonalities, function(seas){
    which.max(seas) %% .period
  })
  seasonal_trough <- map_dbl(seasonalities, function(seas){
    which.min(seas) %% .period
  })

  c(trend_strength = trend_strength, seasonal_strength = seasonal_strength,
    spike = spike, linearity = linearity, curvature = curvature,
    seasonal_peak = seasonal_peak, seasonal_trough = seasonal_trough)
}

#' Unit root tests
#'
#' Performs a test for the existence of a unit root in the vector.
#'
#' \code{unitroot_kpss} computes the statistic for the Kwiatkowski et al. unit root test with linear trend and lag 1.
#'
#' \code{unitroot_pp} computes the statistic for the `'Z-tau'' version of Phillips & Perron unit root test with constant trend and lag 1.
#'
#' @param x A vector to be tested for the unit root.
#' @inheritParams urca::ur.kpss
#' @param ... Unused.
#'
#' @seealso [urca::ur.kpss()]
#'
#' @rdname unitroot
#' @export
unitroot_kpss <- function(x, type = c("mu", "tau"), lags = c("short", "long", "nil"),
                          use.lag = NULL, ...) {
  require_package("urca")
  result <- urca::ur.kpss(x, type = type, lags = lags, use.lag = use.lag)
  pval <- tryCatch(
    stats::approx(result@cval[1,], as.numeric(sub("pct", "", colnames(result@cval)))/100, xout=result@teststat[1], rule=2)$y,
    error = function(e){
      NA
    }
  )
  c(kpss_stat = result@teststat, kpss_pval = pval)
}

#' @inheritParams urca::ur.pp
#' @rdname unitroot
#'
#' @seealso [urca::ur.pp()]
#'
#' @export
unitroot_pp <- function(x, type = c("Z-tau", "Z-alpha"), model = c("constant", "trend"),
                        lags = c("short", "long"), use.lag = NULL, ...) {
  require_package("urca")
  result <- urca::ur.pp(x, type = type, model = model, lags = lags, use.lag = use.lag)
  pval <- tryCatch(
    stats::approx(result@cval[1,], as.numeric(sub("pct", "", colnames(result@cval)))/100, xout=result@teststat[1], rule=2)$y,
    error = function(e){
      NA
    }
  )
  c(pp_stat = result@teststat, pp_pval = pval)
}

#' Number of differences required for a stationary series
#'
#' Use a unit root function to determine the minimum number of differences
#' necessary to obtain a stationary time series.
#'
#' @inheritParams unitroot_kpss
#' @param alpha The level of the test.
#' @param unitroot_fn A function (or lambda) that provides a p-value for a unit root test.
#' @param differences The possible differences to consider.
#' @param ... Additional arguments passed to the `unitroot_fn` function
#'
#' @export
unitroot_ndiffs <- function(x, alpha = 0.05, unitroot_fn = ~ unitroot_kpss(.)["kpss_pval"],
                            differences = 0:2, ...) {
  unitroot_fn <- as_function(unitroot_fn)

  diff <- function(x, differences, ...){
    if(differences == 0) return(x)
    base::diff(x, differences = differences, ...)
  }

  # Non-missing x
  keep <- map_lgl(differences, function(.x){
    dx <- diff(x, differences = .x)
    !all(is.na(dx))
  })
  differences <- differences[keep]

  # Estimate the test
  keep <- map_lgl(differences[-1]-1, function(.x) {
    unitroot_fn(diff(x, differences = .x), ...) < alpha
  })

  c(ndiffs = max(differences[c(TRUE, keep)], na.rm = TRUE))
}

#' @rdname unitroot_ndiffs
#' @param .period The period of the seasonality.
#'
#' @export
unitroot_nsdiffs <- function(x, alpha = 0.05, unitroot_fn = ~ stl_features(.,.period)%>%
                               {.[grepl("seasonal_strength",names(.))][1]<0.64},
                             differences = 0:2, .period = 1, ...) {
  if(.period == 1) return(c(nsdiffs = min(differences)))

  unitroot_fn <- as_function(unitroot_fn)

  diff <- function(x, differences, ...){
    if(differences == 0) return(x)
    base::diff(x, differences = differences, ...)
  }

  # Non-missing x
  keep <- map_lgl(differences, function(.x){
    dx <- diff(x, lag = .period, differences = .x)
    !all(is.na(dx))
  })
  differences <- differences[keep]

  # Estimate the test
  keep <- map_lgl(differences[-1]-1, function(.x) {
    unitroot_fn(diff(x, lag = .period, differences = .x)) < alpha
  })

  c(nsdiffs = max(differences[c(TRUE, keep)], na.rm = TRUE))
}

#' Number of flat spots
#'
#' Number of flat spots in a time series
#' @param x a vector
#' @param ... Unused.
#' @return A numeric value.
#' @author Earo Wang and Rob J Hyndman
#' @export
flat_spots <- function(x) {
  cutx <- try(cut(x, breaks = 10, include.lowest = TRUE, labels = FALSE),
              silent = TRUE
  )
  if (class(cutx) == "try-error") {
    return(c(flat_spots = NA))
  }
  rlex <- rle(cutx)
  return(c(flat_spots = max(rlex$lengths)))
}

#' Hurst coefficient
#'
#' Computes the Hurst coefficient indicating the level of fractional differencing
#' of a time series.
#'
#' @param x a vector. If missing values are present, the largest
#' contiguous portion of the vector is used.
#' @param ... Unused.
#' @return A numeric value.
#' @author Rob J Hyndman
#'
#' @export
hurst <- function(x, ...) {
  require_package("fracdiff")
  # Hurst=d+0.5 where d is fractional difference.
  return(c(hurst = suppressWarnings(fracdiff::fracdiff(na.contiguous(x), 0, 0)[["d"]] + 0.5)))
}

#' Sliding window features
#'
#' Computes feature of a time series based on sliding (overlapping) windows.
#' \code{max_level_shift} finds the largest mean shift between two consecutive windows.
#' \code{max_var_shift} finds the largest var shift between two consecutive windows.
#' \code{max_kl_shift} finds the largest shift in Kulback-Leibler divergence between
#' two consecutive windows.
#'
#' Computes the largest level shift and largest variance shift in sliding mean calculations
#' @param x a univariate time series
#' @param .size size of sliding window, if NULL `.size` will be automatically chosen using `.period`
#' @param .period The seasonal period (optional)
#' @param ... Unused.
#' @return A vector of 2 values: the size of the shift, and the time index of the shift.
#'
#' @author Earo Wang, Rob J Hyndman and Mitchell O'Hara-Wild
#'
#' @export
max_level_shift <- function(x, .size = NULL, .period = 1, ...) {
  if(is.null(.size)){
    .size <- ifelse(.period == 1, 10, .period)
  }

  rollmean <- tsibble::slide_dbl(x, mean, .size = .size, na.rm = TRUE)

  means <- abs(diff(rollmean, .size))
  if (length(means) == 0L) {
    maxmeans <- 0
    maxidx <- NA_real_
  }
  else if (all(is.na(means))) {
    maxmeans <- NA_real_
    maxidx <- NA_real_
  }
  else {
    maxmeans <- max(means, na.rm = TRUE)
    maxidx <- which.max(means) + 1L
  }

  return(c(level_shift_max = maxmeans, level_shift_index = maxidx))
}

#' @rdname max_level_shift
#' @export
max_var_shift <- function(x, .size = NULL, .period = 1, ...) {
  if(is.null(.size)){
    .size <- ifelse(.period == 1, 10, .period)
  }

  rollvar <- tsibble::slide_dbl(x, var, .size = .size, na.rm = TRUE)

  vars <- abs(diff(rollvar, .size))

  if (length(vars) == 0L) {
    maxvar <- 0
    maxidx <- NA_real_
  }
  else if (all(is.na(vars))) {
    maxvar <- NA_real_
    maxidx <- NA_real_
  }
  else {
    maxvar <- max(vars, na.rm = TRUE)
    maxidx <- which.max(vars) + 1L
  }

  return(c(var_shift_max = maxvar, var_shift_index = maxidx))
}

#' @rdname max_level_shift
#' @export
max_kl_shift <- function(x, .size = NULL, .period = 1, ...) {
  if(is.null(.size)){
    .size <- ifelse(.period == 1, 10, .period)
  }

  gw <- 100 # grid width
  xgrid <- seq(min(x, na.rm = TRUE), max(x, na.rm = TRUE), length = gw)
  grid <- xgrid[2L] - xgrid[1L]
  tmpx <- x[!is.na(x)] # Remove NA to calculate bw
  bw <- stats::bw.nrd0(tmpx)
  lenx <- length(x)
  if (lenx <= (2 * .size)) {
    return(c(max_kl_shift = NA_real_, time_kl_shift = NA_real_))
  }

  densities <- map(xgrid, function(xgrid) stats::dnorm(xgrid, mean = x, sd = bw))
  densities <- map(densities, pmax, stats::dnorm(38))

  rmean <- map(densities, function(x)
    tsibble::slide_dbl(x, mean, .size = .size, na.rm = TRUE, .align = "right")
  ) %>%
    transpose() %>%
    map(unlist)

  kl <- map2_dbl(
    rmean[seq_len(lenx - .size)],
    rmean[seq_len(lenx - .size) + .size],
    function(x, y) sum(x * (log(x) - log(y)) * grid, na.rm = TRUE)
  )

  diffkl <- diff(kl, na.rm = TRUE)
  if (length(diffkl) == 0L) {
    diffkl <- 0
    maxidx <- NA_real_
  }
  else {
    maxidx <- which.max(diffkl) + 1L
  }
  return(c(kl_shift_max = max(diffkl, na.rm = TRUE), kl_shift_index = maxidx))
}

#' Spectral entropy of a time series
#'
#' Computes the spectral entropy of a time series
#'
#' @inheritParams max_level_shift
#'
#' @return A numeric value.
#' @author Rob J Hyndman
#' @export
entropy <- function(x, ...) {
  require_package("ForeCA")
  entropy <- try(ForeCA::spectral_entropy(na.contiguous(x))[1L], silent = TRUE)
  if (class(entropy) == "try-error") {
    entropy <- NA
  }
  return(c(entropy = entropy))
}

#' Time series features based on tiled windows
#'
#' Computes feature of a time series based on tiled (non-overlapping) windows.
#' Means or variances are produced for all tiled windows. Then stability is
#' the variance of the means, while lumpiness is the variance of the variances.
#'
#' @inheritParams max_level_shift
#' @return A numeric vector of length 2 containing a measure of lumpiness and
#' a measure of stability.
#' @author Earo Wang and Rob J Hyndman
#'
#' @rdname tile_features
#'
#' @importFrom stats var
#' @export
lumpiness <- function(x, .size = NULL, .period = 1, ...) {
  if(is.null(.size)){
    .size <- ifelse(.period == 1, 10, .period)
  }

  x <- scale(x, center = TRUE, scale = TRUE)
  varx <- tsibble::tile_dbl(x, var, na.rm = TRUE, .size = .size)

  if (length(x) < 2 * .size) {
    lumpiness <- 0
  } else {
    lumpiness <- var(varx, na.rm = TRUE)
  }
  return(c(lumpiness = lumpiness))
}

#' @rdname tile_features
#' @export
stability <- function(x, .size = NULL, .period = 1, ...) {
  if(is.null(.size)){
    .size <- ifelse(.period == 1, 10, .period)
  }

  x <- scale(x, center = TRUE, scale = TRUE)
  meanx <- tsibble::tile_dbl(x, mean, na.rm = TRUE, .size = .size)

  if (length(x) < 2 * .size) {
    stability <- 0
  } else {
    stability <- var(meanx, na.rm = TRUE)
  }
  return(c(stability = stability))
}

#' Autocorrelation-based features
#'
#' Computes various measures based on autocorrelation coefficients of the
#' original series, first-differenced series and second-differenced series
#'
#' @inheritParams stability
#'
#' @return A vector of 6 values: first autocorrelation coefficient and sum of squared of
#' first ten autocorrelation coefficients of original series, first-differenced series,
#' and twice-differenced series.
#' For seasonal data, the autocorrelation coefficient at the first seasonal lag is
#' also returned.
#'
#' @author Thiyanga Talagala
#' @export
acf_features <- function(x, .period = 1, ...) {
  acfx <- stats::acf(x, lag.max = max(.period, 10L), plot = FALSE, na.action = stats::na.pass)
  acfdiff1x <- stats::acf(diff(x, differences = 1), lag.max = 10L, plot = FALSE, na.action = stats::na.pass)
  acfdiff2x <- stats::acf(diff(x, differences = 2), lag.max = 10L, plot = FALSE, na.action = stats::na.pass)

  # first autocorrelation coefficient
  acf_1 <- acfx$acf[2L]

  # sum of squares of first 10 autocorrelation coefficients
  sum_of_sq_acf10 <- sum((acfx$acf[2L:11L])^2)

  # first autocorrelation coefficient of differenced series
  diff1_acf1 <- acfdiff1x$acf[2L]

  # Sum of squared of first 10 autocorrelation coefficients of differenced series
  diff1_acf10 <- sum((acfdiff1x$acf[-1L])^2)

  # first autocorrelation coefficient of twice-differenced series
  diff2_acf1 <- acfdiff2x$acf[2L]

  # Sum of squared of first 10 autocorrelation coefficients of twice-differenced series
  diff2_acf10 <- sum((acfdiff2x$acf[-1L])^2)

  output <- c(
    x_acf1 = unname(acf_1),
    x_acf10 = unname(sum_of_sq_acf10),
    diff1_acf1 = unname(diff1_acf1),
    diff1_acf10 = unname(diff1_acf10),
    diff2_acf1 = unname(diff2_acf1),
    diff2_acf10 = unname(diff2_acf10)
  )

  if (.period > 1) {
    output <- c(output, seas_acf1 = unname(acfx$acf[.period + 1L]))
  }

  return(output)
}

#' Partial autocorrelation-based features
#'
#' Computes various measures based on partial autocorrelation coefficients of the
#' original series, first-differenced series and second-differenced series.
#'
#' @inheritParams acf_features
#'
#' @return A vector of 3 values: Sum of squared of first 5
#' partial autocorrelation coefficients of the original series, first differenced
#' series and twice-differenced series.
#' For seasonal data, the partial autocorrelation coefficient at the first seasonal
#' lag is also returned.
#' @author Thiyanga Talagala
#' @export
pacf_features <- function(x, .period = 1, ...) {
  pacfx <- stats::pacf(x, lag.max = max(5L, .period), plot = FALSE)$acf
  # Sum of squared of first 5 partial autocorrelation coefficients
  pacf_5 <- sum((pacfx[seq(5L)])^2)

  # Sum of squared of first 5 partial autocorrelation coefficients of difference series
  diff1_pacf_5 <- sum((stats::pacf(diff(x, differences = 1), lag.max = 5L, plot = FALSE)$acf)^2)

  # Sum of squared of first 5 partial autocorrelation coefficients of twice differenced series
  diff2_pacf_5 <- sum((stats::pacf(diff(x, differences = 2), lag.max = 5L, plot = FALSE)$acf)^2)

  output <- c(
    x_pacf5 = unname(pacf_5),
    diff1x_pacf5 = unname(diff1_pacf_5),
    diff2x_pacf5 = unname(diff2_pacf_5)
  )
  if (.period > 1) {
    output <- c(output, seas_pacf = pacfx[.period])
  }

  return(output)
}
