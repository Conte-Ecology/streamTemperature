#' @title prepData: Wrapper to prepare data for analysis or predictions
#'
#' @description
#' \code{prepData} Wrapper to prepare data for analysis or predictions
#'
#' @param catches Vector of catchment featureid to prepare for analysis
#' @param springFallBPs Dataframe of spring-fall breakpoints
#' @param df_covariates_upstream Dataframe of covariates
#' @param tempDataSync Data used for modeling in JAGS
#' @param featureid_lat_lon Dataframe linking featureid to lat and lon
#' @param featureid_huc8 Dataframe linking featureid to hucs
#' @param rand_ids Dataframe of random site, huc, and year info
#' @param df_stds Dataframe of means and standard deviations used for standardizing continuous covariates
#' @details
#' This function is a mess but currently works. Lots of redundancy, especially in the data imported.
#' var: blah, blah, blah
#' value: something, something
#' @export
prepData <- function (catches, springFallBPs, df_covariates_upstream, tempDataSync, featureid_lat_lon, featureid_huc8, rand_ids, df_stds) {
  drv <- dbDriver("PostgreSQL")
  con <- dbConnect(drv, dbname = "sheds_new", host = "osensei.cns.umass.edu",
                   user = options("SHEDS_USERNAME"), password = options("SHEDS_PASSWORD"))
  # qry_daymet <- paste0("SELECT featureid, date, tmax, tmin, prcp, dayl, srad, vp, swe, (tmax + tmin) / 2.0 AS airtemp FROM daymet WHERE featureid IN (",catches_string, ") ;")
  # rs <- dbSendQuery(con, statement = qry_daymet)
  # climateData <- dbFetch(rs, n = -1)
  # dbClearResult(rs)
  
  climateData <- get_daymet_featureids(con, featureids = catches)
  dbDisconnect(con)
  
  mean.spring.bp <- mean(dplyr::filter(springFallBPs, finalSpringBP !=
                                         "Inf")$finalSpringBP, na.rm = T)
  mean.fall.bp <- mean(dplyr::filter(springFallBPs, finalFallBP !=
                                       "Inf")$finalFallBP, na.rm = T)
  foo <- springFallBPs %>% 
    dplyr::mutate(site = as.character(site),
                  featureid = as.integer(site),
                  finalSpringBP = ifelse(finalSpringBP == "Inf" | is.na(finalSpringBP), mean.spring.bp, finalSpringBP),
                  finalFallBP = ifelse(
                    finalFallBP == "Inf" | is.na(finalFallBP),
                    mean.fall.bp, finalFallBP))
  
  fullDataSync <- climateData %>% 
    left_join(df_covariates_upstream) %>% 
    left_join(dplyr::select(tempDataSync,date, featureid, site, temp)) %>%
    left_join(featureid_huc8) %>% 
    left_join(featureid_lat_lon) %>% 
    dplyr::mutate(year = as.numeric(format(date,"%Y")), 
                  airTemp = (tmax + tmin) / 2) %>% 
    left_join(dplyr::select(foo,-site)) %>% 
    dplyr::mutate(finalSpringBP = ifelse(finalSpringBP == "Inf" | is.na(finalSpringBP), mean.spring.bp, finalSpringBP),
                  finalFallBP = ifelse(finalFallBP == "Inf" | is.na(finalFallBP), mean.fall.bp, finalFallBP)) %>% 
    dplyr::mutate(dOY = yday(date)) %>%
    dplyr::filter(AreaSqKM < 1000)
  
  rm(climateData)
  gc()
  
  fullDataSync <- fullDataSync[order(fullDataSync$featureid,
                                     fullDataSync$year, fullDataSync$dOY),]
  
  fullDataSync <- fullDataSync %>% 
    group_by(featureid, year) %>%
    arrange(featureid, year, dOY) %>% 
    mutate(
      impoundArea = AreaSqKM * allonnet / 100, 
      airTempLagged1 = lag(airTemp, n = 1, fill = NA),
      temp5p = rollapply(data = airTempLagged1, width = 5,
                         FUN = mean, align = "right", fill = NA, na.rm = T),
      temp7p = rollapply(data = airTempLagged1, width = 7,
                         FUN = mean, align = "right", fill = NA, na.rm = T),
      prcp2 = rollsum(x = prcp, 2, align = "right", fill = NA),
      prcp7 = rollsum(x = prcp, 7, align = "right", fill = NA),
      prcp30 = rollsum(x = prcp, 30, align = "right", fill = NA)
    )
  
  fullDataSync <- fullDataSync %>% 
    dplyr::filter(
      dOY >= finalSpringBP & dOY <= finalFallBP | is.na(finalSpringBP) | is.na(finalFallBP & finalSpringBP != "Inf" & finalFallBP != "Inf"))# %>% 
   # dplyr::filter(dOY >= mean.spring.bp & dOY <= mean.fall.bp)
  
  var.names <- c(
    "airTemp", "temp7p", "prcp", "prcp2", "prcp7",
    "prcp30", "dOY", "forest", "herbaceous", "agriculture",
    "devel_hi", "developed", "AreaSqKM", "allonnet", "alloffnet",
    "surfcoarse", "srad", "dayl", "swe", "impoundArea"
  )
  
  fullDataSync <- fullDataSync %>% 
    mutate(
      HUC8 = as.character(HUC8),
      huc8 = as.character(HUC8), 
      huc = as.character(HUC8),
      site = as.numeric(as.factor(featureid))
    )
  
  fullDataSyncS <- stdCovs(x = fullDataSync, y = df_stds, var.names = var.names)
  
  fullDataSyncS <- addInteractions(fullDataSyncS)
  
  fullDataSyncS <- dplyr::arrange(fullDataSyncS, featureid,
                                  date)
  fullDataSyncS$site <- as.character(fullDataSyncS$featureid)
  if (exists("fullDataSyncS$sitef")) {
    fullDataSyncS <- dplyr::select(fullDataSyncS,-sitef)
  }
  fullDataSyncS <-
    fullDataSyncS %>% left_join(rand_ids$df_site) %>%
    left_join(rand_ids$df_huc) %>% left_join(rand_ids$df_year)
  fullDataSyncS <- indexDeployments(fullDataSyncS, regional = TRUE)
  
  return(list(fullDataSync = fullDataSync, fullDataSyncS = fullDataSyncS))
}


#' @title addInteractions: Add intercepts, interaction, and polynomial terms to dataframe
#'
#' @description
#' \code{addInteractions} Add intercepts, interaction, and polynomial terms to dataframe
#'
#' @param data Dataframe of covariates to model or predict daily stream temperature
#' @return Original dataframe plus the additional terms
#' @details
#' By making this a function it can easily get added to multiple places in the data prep for validation, fitting, or predicting. Then there is only one place where the interactions have to be specified
#' @examples
#' 
#' \dontrun{
#' tempDataSyncS <- addInteractions(tempDataSyncS)
#' }
#' @export
addInteractions <- function(data) {
  data <- data %>%
    dplyr::mutate(intercept = 1 
                  , intercept.site = 1
                  , intercept.year = 1
                  , dOY2 = dOY ^ 2
                  , dOY3 = dOY ^ 3
                  , airTemp.forest = airTemp * forest # change to riparian forest
                  , prcp2.da = prcp2 * AreaSqKM
                  , airTemp.prcp2.da = airTemp * prcp2 * AreaSqKM
                  , airTemp.prcp2.da.forest = airTemp * prcp2 * AreaSqKM * forest # change to riparian forest
                  , prcp30.da = prcp30 * AreaSqKM
                  , airTemp.da = airTemp * AreaSqKM
                  , airTemp.prcp2 = airTemp * prcp2
                  , airTemp.prcp30 = airTemp * prcp30
                  , airTemp.prcp30.da = airTemp * prcp30 * AreaSqKM
                  , airTemp.agriculture = airTemp * agriculture
                  , airTemp.devel_hi = airTemp * devel_hi
                  , temp7p.forest = temp7p * forest
                  , prcp7.da = prcp7 * AreaSqKM
                  , temp7p.prcp7.da = temp7p * prcp7 * AreaSqKM
                  , temp7p.forest.prcp7.da = temp7p * forest * prcp7 * AreaSqKM
                  , srad.forest = srad * forest # change to riparian forest?
                  , airTemp.swe = airTemp * swe
                  #, airTempLagged1.swe = airTempLagged1 * swe
                  #, airTempLagged2.swe = airTempLagged2 * swe
                  , airTemp.allonnet = airTemp * allonnet
                  , airTemp.alloffnet = airTemp * alloffnet
                  , allonnet2 = allonnet * allonnet
                  , airTemp.allonnet2 = airTemp * allonnet *allonnet
                  , airTemp.impoundArea = airTemp * impoundArea
                  , impoundArea2 = impoundArea * impoundArea
                  , airTemp.impoundArea2 = airTemp * impoundArea2
                  , devel_hi.prcp2.da = devel_hi * prcp2 * AreaSqKM
                  , agriculture.prcp2.da = agriculture * prcp2 * AreaSqKM
    )
  return(data)
}



#' @title indexDeployments: Create an index for each unique temperature logger deployment
#'
#' @description
#' \code{indexDeployments} returns the input dataframe with a deployment ID added as a column
#'
#' @param data Dataframe of temperature data including date and unique site ID
#' @param regional Optional logical if true then also sort the dataframe by HUC8
#' @details
#' var: blah, blah, blah
#' value: something, something
#' @export
indexDeployments <- function (data, regional = FALSE) {
  tbl_df(data)
  data <- ungroup(data)
  data$sitef <- as.numeric(as.factor(data$site))
  data$huc8f <- as.numeric(as.factor(data$HUC8))
  if (regional) {
    data <- arrange(data, huc8f, site, date)
  }
  else {
    data <- arrange(data, site, date)
  }
  data$rowNum <- 1:nrow(data)
  data$siteShift <- c(1, data$sitef[1:(nrow(data) - 1)])
  data$dateShift <- c(1, data$date[1:(nrow(data) - 1)])
  data <- data %>%
    dplyr::mutate(newSite = sitef ==  siteShift + 1,
                  newDate = date != dateShift + 1, 
                  isNA = is.na(temp), 
                  isNAShift = c(FALSE, isNA[1:(nrow(data) - 1)]), 
                  newDeploy = (newSite | newDate | isNAShift) * 1, 
                  deployID = cumsum(newDeploy))
  return(data)
}


#' @title createDeployRows: Create rows to loop through for autoregressive function
#'
#' @description
#' \code{createDeployRows} returns a list of two dataframes each with a rowNum column for looping
#'
#' @param data Dataframe for analysis with date and a deployID row (can generate with indexDeployments function)
#' @details
#' var: blah, blah, blah
#' value: something, something
#' @export
createFirstRows <- function(data) {
  #data$rowNum <- 1:dim(data)[1] This is created in indexDeployments
  
  firstObsRows <- data %>%
    group_by(deployID) %>%
    filter( date == min(date) | is.na(temp) ) %>%
    select(rowNum)
  
  return( firstObsRows$rowNum ) # this can be a list or 1 dataframe with different columns. can't be df - diff # of rows
}

#' @title createEvalRows: Create rows to loop through for autoregressive function
#'
#' @description
#' \code{createDeployRows} returns a list of two dataframes each with a rowNum column for looping
#'
#' @param data Dataframe for analysis with date and a deployID row (can generate with indexDeployments function)
#' @details
#' var: blah, blah, blah
#' value: something, something
#' @export
createEvalRows <- function(data) {
  #data$rowNum <- 1:dim(data)[1]
  evalRows <- data %>%
    group_by(deployID) %>%
    filter(date != min(date) & !is.na(temp)) %>%
    #filter(date != min(date) | !is.na(temp)) %>%
    select(rowNum)
  
  return( evalRows$rowNum ) # this can be a list or 1 dataframe with different columns. can't be df - diff # of rows
}

#' @title addStreamMuResid 
#'
#' @description
#' \code{addStreamMuResid} get means for stream.mu and resid from the jags output. append means to tempDataSyncS
#'
#' @param M,tempDataSyncS
#' @details
#' var: blah, blah, blah
#' value: something, something
#' @export
addStreamMuResid <- function(M.wb,tempDataSyncS){
    
  getMeansStreamMuResid <- 
    M.wb %>%
    as.matrix(.) %>%
    melt(.) %>%
    group_by(Var2) %>%
    summarise( mean = mean(value) ) %>%
    mutate( rowNum = as.numeric( substring(Var2,regexpr("\\[",Var2)+1,regexpr("\\]",Var2)-1) ) ) %>%
    filter( row_number() %in% grep("stream.mu",x=Var2) | 
            row_number() %in% grep("residuals",x=Var2)) 
  
  m1 <- getMeansStreamMuResid %>%
    filter(row_number() %in% grep("residuals",x=Var2) ) %>%
    mutate( resid.wb = mean ) 
  
  tempDataSyncS$resid.wb <- NULL
  tempDataSyncS <- left_join( tempDataSyncS,m1[,c('rowNum','resid.wb')], by = 'rowNum')
  
  m2 <- getMeansStreamMuResid %>%
    filter(row_number() %in% grep("stream.mu",x=Var2) ) %>%
    mutate( pred.wb = mean ) 
  
  tempDataSyncS$pred.wb <- NULL
  tempDataSyncS <- left_join( tempDataSyncS,m2[,c('rowNum','pred.wb')], by = 'rowNum')
  
  return( tempDataSyncS )
  
}

#' @title not in: 
#'
#' @description
#' \code{!in} antii %in%
#'
#' @param x
#' @param table
#' @details
#' var: blah, blah, blah
#' value: something, something
#' @export
"%!in%" <- function(x, table) match(x, table, nomatch = 0) == 0

#' @title prepDataWrapper: Wrapper to prepare data for analysis or predictions
#'
#' @description
#' \code{prepDataWrapper} Wrapper to prepare data for analysis or predictions
#'
#' @param var.names Character vector naming the variables to standardize for analysis
#' @param File directory and name for output objects
#' @details
#' var: blah, blah, blah
#' value: something, something
#' @export
prepDataWrapper <- function(data.fit = NULL, var.names, dataInDir, dataOutDir, predict.daymet = FALSE, validate = FALSE, validateFrac = NULL, filter.area = NULL, file) {
  
  # need to import climate data
  
  if(predict.daymet) {
    
    covariateData <- readStreamTempData(timeSeries=FALSE, covariates=TRUE, dataSourceList=dataSource, fieldListTS=fields, fieldListCD='ALL', directory=dataInDir)
    
    observedData <- readStreamTempData(timeSeries=TRUE, covariates=FALSE, dataSourceList=dataSource, fieldListTS=fields, fieldListCD='ALL', directory=dataInDir)
    
    springFallBPs$site <- as.character(springFallBPs$site)
    ########## How to add BP for years without data and clip data to the sync period ??? #######
    # Join with break points
    # covariateDataBP <- left_join(covariateData, springFallBPs, by=c('site', 'year'))
    # rm(covariateData)
    
    # temp hack
    climateData$site <- as.character(climateData$site)
    tempData <- left_join(climateData, select(covariateData, -Latitude, -Longitude), by=c('site'))
    tempData <- left_join(tempData, select(observedData, agency, data, AgencyID, site, temp), by = c("site", "date"))
    tempDataBP <- left_join(tempData, springFallBPs, by=c('site', 'year'))
    
    # Clip to syncronized season
    # tempFullSync <- filter(tempDataBP, dOY >= finalSpringBP & dOY <= finalFallBP)
    
    # temp hack - eventually need to adjust Kyle's code to substitute huc or other mean breakpoint in when NA
    tempDataSync <- tempDataBP %>%
      filter(dOY >= finalSpringBP & dOY <= finalFallBP | is.na(finalSpringBP) | is.na(finalFallBP)) %>%
      filter(dOY >= mean(finalSpringBP, na.rm = T) & dOY <= mean(finalFallBP, na.rm = T))
    
    rm(climateData) # save some memory
    ##################
  } else {
    
    
    covariateData <- readStreamTempData(timeSeries=TRUE, covariates=TRUE, dataSourceList=dataSource, fieldListTS=fields, fieldListCD='ALL', directory=dataInDir)
    
    springFallBPs$site <- as.character(springFallBPs$site)
    
    # Join with break points
    tempDataBP <- left_join(covariateData, springFallBPs, by=c('site', 'year'))
    
    # Clip to syncronized season
    tempDataSync <- dplyr::filter(tempDataBP, dOY >= finalSpringBP & dOY <= finalFallBP)
  }
  
  rm(covariateData) # save some memory
  
  # Order by group and date
  tempDataSync <- tempDataSync[order(tempDataSync$site,tempDataSync$year,tempDataSync$dOY),]
  
  # For checking the order of tempDataSync
  tempDataSync$count <- 1:length(tempDataSync$year)
  
  tempDataSync <- tempDataSync[order(tempDataSync$count),] # just to make sure tempDataSync is ordered for the slide function
  
  # airTemp
  tempDataSync <- slide(tempDataSync, Var = "airTemp", GroupVar = "site", slideBy = -1, NewVar='airTempLagged1')
  tempDataSync <- slide(tempDataSync, Var = "airTemp", GroupVar = "site", slideBy = -2, NewVar='airTempLagged2')
  
  # prcp
  tempDataSync <- slide(tempDataSync, Var = "prcp", GroupVar = "site", slideBy = -1, NewVar='prcpLagged1')
  tempDataSync <- slide(tempDataSync, Var = "prcp", GroupVar = "site", slideBy = -2, NewVar='prcpLagged2')
  tempDataSync <- slide(tempDataSync, Var = "prcp", GroupVar = "site", slideBy = -3, NewVar='prcpLagged3')
  
  # Make dataframe with just variables for modeling and order before standardizing
 # if(predict.daymet) {
  #  tempDataSync <- tempDataSync[ , c("date", "year", "site", "date", "finalSpringBP", "finalFallBP", "FEATUREID", "HUC4", "HUC8", "HUC12", "maxAirTemp", "minAirTemp", "Latitude", "Longitude", "airTemp", "airTempLagged1", "airTempLagged2", "prcp", "prcpLagged1", "prcpLagged2", "prcpLagged3", "dOY", "Forest", "Herbacious", "Agriculture", "Developed", "TotDASqKM", "ReachElevationM", "ImpoundmentsAllSqKM", "HydrologicGroupAB", "SurficialCoarseC", "CONUSWetland", "ReachSlopePCNT", "srad", "dayl", "swe")] #
 # } else {
    tempDataSync <- tempDataSync[ , c("agency", "date", "AgencyID", "year", "site", "date", "finalSpringBP", "finalFallBP", "FEATUREID", "HUC4", "HUC8", "HUC12", "temp", "Latitude", "Longitude", "airTemp", "airTempLagged1", "airTempLagged2", "prcp", "prcpLagged1", "prcpLagged2", "prcpLagged3", "dOY", "Forest", "Herbacious", "Agriculture", "Developed", "TotDASqKM", "ReachElevationM", "ImpoundmentsAllSqKM", "HydrologicGroupAB", "SurficialCoarseC", "CONUSWetland", "ReachSlopePCNT", "srad", "dayl", "swe")] #  
  #}
  
  if(class(filter.area) == "numeric") tempDataSync <- filter(tempDataSync, filter = TotDASqKM <= filter.area)
  
  tempDataSync <- na.omit(tempDataSync) ####### Needed to take out first few days that get NA in the lagged terms. Change this so don't take out NA in stream temperature?
  
  ### Separate data for fitting (training) and validation
  
  #If validating:
  if(validate) {
    n.fit <- floor(length(unique(tempDataSync$site)) * (1 - validateFrac))
    
    set.seed(2346)
    site.fit <- sample(unique(tempDataSync$site), n.fit, replace = FALSE) # select sites to hold back for testing 
    tempDataSyncValid <- subset(tempDataSync, !site %in% site.fit) # data for validation
    tempDataSync <- subset(tempDataSync, site %in% site.fit)    # data for model fitting (calibration)
    
    tempDataSyncValidS <- stdCovs(x = tempDataSyncValid, y = tempDataSync, var.names = var.names)
    
    tempDataSyncValidS <- indexDeployments(tempDataSyncValidS, regional = TRUE)
    firstObsRowsValid <- createFirstRows(tempDataSyncValidS)
    evalRowsValid <-createEvalRows(tempDataSyncValidS)
    
  } else {
    tempDataSyncValid <- NULL
  }
  
  # Standardize for Analysis
  
  tempDataSyncS <- stdFitCovs(x = tempDataSync, var.names = var.names)
  
  tempDataSyncS <- addInteractions(tempDataSyncS)
  
  if(!predict.daymet) {
    tempDataSyncS <- indexDeployments(tempDataSyncS, regional = TRUE)
    firstObsRows <- createFirstRows(tempDataSyncS)
    evalRows <- createEvalRows(tempDataSyncS)
    
    if(validate) {
      
      tempDataSyncValidS <- addInteractions(tempDataSyncValidS)
      
      save(tempDataSync, tempDataSyncS, tempDataSyncValid, tempDataSyncValidS, firstObsRows, evalRows, firstObsRowsValid, evalRowsValid, file = file)
    } else {
      save(tempDataSync, tempDataSyncS, firstObsRows, evalRows, file = file)
    }
  } else {
    save(tempDataSync, tempDataSyncS, file = file)
  }
}


#' @title prepDF: Prepares dataframe for use or prediction
#'
#' @description
#' \code{prepDF} Prepares dataframe for use or prediction
#'
#' @param data Dataframe of potential covariates to model or predict daily stream temperature
#' @param form Named list of formulae each created with the formula function. Names must be data.fixed, data.random.sites, and data.random.years.
#' @return List of named data frames each created using model.matrix and the input formulae
#' @details
#' blah, blah, blah
#' @examples
#' 
#' \dontrun{
#' data.list <- prepDF(data = tempDataSyncS, cov.list = cov.list)
#' }
#' @export
prepDF <- function(data, covars) {

  data <- addInteractions(data = data)
  
  data.fixed <- data %>%
    select(one_of(covars$fixed.ef))
  
  data.random.sites <- data %>%
    select(one_of(covars$site.ef))
  
  data.random.years <- data %>%
    select(one_of(covars$year.ef))
  
  data.cal <- list(data.fixed = data.fixed, data.random.sites = data.random.sites, data.random.years = data.random.years)
  
  return(data.cal)
}


