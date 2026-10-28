# BMIP climate data (CHELSA V2.1) – information on the EBV netCDF files

Contact: Robert Hering, robert.hering\@uni-potsdam.de; Jette Wolff, jette.wolff\@uni-potsdam.de · Date of this description: 28.10.2026

------------------------------------------------------------------------

## 1. What is in the netCDF files

16 files, one per region and product, named `<Region>-<product>.nc`:

| Region | Area |
|------------------------------------|------------------------------------|
| Australia | oval region in north-eastern Queensland (not the whole continent) |
| Europe, Finland, USA | masks of the respective BMIP study regions |

| Product | Content | Resolution | Time axis |
|------------------|------------------|------------------|------------------|
| `monthly_1km` | monthly values of 6 climate variables | 1 km | 1941-01 to 2024-12, 1008 monthly steps |
| `daily_10km` | daily values of the same variables | 10 km | 1941-01-01 to 2024-12-31, 30681 daily steps |
| `annual_bioclim_1km` | 19 bioclimatic variables per year | 1 km | one step per year, 1941–2024 (see below) |
| `annual_bioclim_10km` | the same at 10 km | 10 km | one step per year, 1941–2024 (see below) |

**Variables of `monthly_1km` and `daily_10km`** (one metric each):

| Code | Variable | Unit | Monthly value |
|------------------|------------------|------------------|------------------|
| `prec` | precipitation | kg m-2 day-1 | sum |
| `tas` | mean air temperature | K | mean |
| `tasmin` | daily minimum temperature | K | mean of the daily minima |
| `tasmax` | daily maximum temperature | K | mean of the daily maxima |
| `rsds` | surface downwelling shortwave radiation | W m-2 | mean |
| `hurs` | near-surface relative humidity | percent (0–100) | mean |

**Bioclimatic variables** (`bio1` … `bio19`, the standard WorldClim/CHELSA definitions) are computed for each year from the monthly precipitation, minimum and maximum temperature of that year. Temperature-based variables are in °C, precipitation-based variables in kg m-2 day-1.

**Spatial reference:** each region has its own projected grid (the coordinate reference system, extent and resolution are stored in the file). Cells outside the study region are NA (fill value `9.9692099683868690e+36`).

**Time axis of files:** the time axis already contains the step **2025**, which is reserved for a later addition. That step is currently still **empty** (all NA). Please ignore 2025 in time series and averages.

------------------------------------------------------------------------

## 2. Source and processing

-   **Source:** CHELSA V2.1 daily global data, 30 arcsec resolution, obtained from the CHELSA server (`https://os.unil.cloud.switch.ch/chelsa02/`). Citation: Karger, D. N. (2025). CHELSA-daily climate data at high resolution. EnviDat. <https://www.doi.org/10.16904/envidat.687>. and Karger, D. N.; Conrad, O.; Böhner, J.; Kawohl, T.; Kreft, H.; Soria-Auza, R. W.; Zimmermann, N. E.; Linder, H. P.; Kessler, M. Climatologies at high resolution for the earth's land surface areas. Sci. Data 2017, 4, 170122 (20 pp.). <https://doi.org/10.1038/sdata.2017.122> License: Creative Commons Zero - No Rights Reserved (CC0 1.0).
-   **Monthly 1 km:** each daily file is cropped to the region, resampled to the regional 1 km grid (average), masked, and aggregated per month (mean, precipitation: sum).
-   **Daily 10 km:** the daily files are averaged to the 10 km grid and masked.
-   **Bioclims 1 km:** computed with `predicts::bcvars` from the monthly 1 km files. **Bioclims 10 km:** the 1 km bioclims averaged to 10 km with GDAL (`gdalwarp`, average).
-   **hurs:** the raw files are labelled percent but carry a scale factor of 0.001, so they read as 0–1; the values were multiplied by 100 to give percent.
-   **Software:** R 4.5.1, terra 1.9.50, GDAL 3.10.3, predicts 0.2.2, ebvcube 0.5.3. Scripts: [[repository]](https://github.com/UP-macroecology/BMIP_CHELSAV2.1_dataprep) (see the README of the processing pipeline).

------------------------------------------------------------------------

## 3. Handling of faulty data

All daily source files were tested after download (completeness, checksum, value range, NA fraction, constant files, implausibly low mean or maximum). Faulty days were **not used**:

-   **Daily 10 km:** the day is kept as a layer so that all layers stay aligned with the calendar, but the layer is **empty (all NA)**.
-   **Monthly values:** computed from the remaining days of the month (temperature, rsds, hurs). If no valid day remains the month is NA. For **precipitation**, a month with a missing day would be underestimated (it is a sum), therefore such a month is set to NA. In the delivered data no precipitation month in 1941–2024 was affected.
-   **Bioclims:** are derived from the monthly files and inherit these rules.

| Variable | Reason | Number of days (1941–2024) |
|------------------------|------------------------|------------------------|
| rsds | constant value and/or implausibly low maximum | 29 |
| rsds | implausibly low mean | 5 |
| rsds | values outside the plausible range / checksum error | 3 / 2 |
| tasmax | too many NA / out of range | 12 / 1 |
| tasmin | too many NA / out of range | 2 / 1 |
| tas | out of range | 1 |
| hurs | not available on the server | 61 (1979: 26 days, April 2007: 30 days, 2019: 5 days) |
| hurs | implausibly low mean (source error): 1952-07-31, 1954-11-24, 1989-01-27 | 3 |

The complete list is in **`excluded_days_list.csv`** (variable, date, reason; the same days are excluded in all regions). The months whose values are affected are listed in **`affected_months_list.csv`**. The counts in the table are taken from these files (120 days in total; the same days are empty in all four regions).

Examples: hurs 1979: 26 days missing (January–April, October–December), March 1979 uses 19 of 31 days. One hurs month (April 2007) has no valid day and is NA.

------------------------------------------------------------------------

## 4. Known properties and limitations

-   **Source data are used as delivered.** `tas`, `tasmin` and `tasmax` are separate CHELSA products; in about 15 cases the regional monthly or daily values violate tasmin ≤ tas ≤ tasmax. They were not corrected.
-   **Extreme events are real:** monthly precipitation in north-eastern Queensland in August 1998 and November 2010 are very high but genuine.
-   **Day-to-day changes** of rsds in Finland are natural variability of the regional mean, not errors.
-   Averaging 1 km to 10 km is a mean of the 1 km cells within a 10 km cell; cells at the region boundary are based on fewer 1 km cells.

------------------------------------------------------------------------

## 5. Reading the files

The files follow the EBV netCDF structure (one metric per variable/bioclim, data in groups such as `metric_1/ebv_cube`; time and coordinates in the file). Missing values are the fill value `9.9692099683868690e+36`, which tools translate to NA.

**R (ebvcube):**

``` r
library(ebvcube)
nc <- "Europe-monthly_1km.nc"
dc <- ebv_datacubepaths(nc)                  # list of metrics (variables)
ebv_properties(nc)@temporal$dates            # time steps
# first variable, all months of the first year as a SpatRaster:
r <- ebv_read(nc, dc$datacubepaths[1], entity = 1, timestep = 1:12, type = "r")
# as a plain array (independent of terra/GDAL):
a <- ebv_read(nc, dc$datacubepaths[1], entity = 1, timestep = 1, type = "a")
```

**Other software:** any netCDF4 reader with group support (e.g. Python `xarray`/`netCDF4`, `ncdump -h`, QGIS/GDAL) can be used; first inspect the structure with `ncdump -h <file>`. 

**Please note:**

-   **Zero values are real data** (e.g. dry months in the precipitation-based bioclims `bio14`, `bio17`). We observed that `ebv_read(..., type = "r")` returned NA instead of 0 with terra 1.9.50 and GDAL 3.10.3. If zero cells appear as NA, read as an array (`type = "a"`) or use another terra/GDAL version.
-   The bioclim files contain an empty time step for **2025** (see section 1).
-   Temperatures are in Kelvin in the monthly and daily files and in °C in the bioclims.
