% Generated by roxygen2: do not edit by hand
% Please edit documentation in R/QAQC.R
\name{flag_cold_obs}
\alias{flag_cold_obs}
\title{flag_cold_obs}
\usage{
flag_cold_obs(data)
}
\arguments{
\item{data}{time series data pull from the postgres database (df_values table)}
}
\value{
Flagging observations < -1 C
}
\description{
\code{flag_cold_obs} Flagging observations < -1 C
}
\details{
Flagging observations < -1 C
}
\examples{

\dontrun{

}
}

