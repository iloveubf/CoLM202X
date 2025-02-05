#include <define.h>

PROGRAM CoLM
   ! ======================================================================
   ! Reference:
   !     [1] Dai et al., 2003: The Common Land Model (CoLM).
   !         Bull. of Amer. Meter. Soc., 84: 1013-1023
   !     [2] Dai et al., 2004: A two-big-leaf model for canopy temperature,
   !         photosynthesis and stomatal conductance. J. Climate, 17: 2281-2299.
   !     [3] Dai et al., 2014: The Terrestrial Modeling System (TMS).
   !     [4] Dai Yamazaki, 2014: The global river model CaMa-Flood (version 3.6.2)
   !
   !     Created by Yongjiu Dai, Februay 2004
   !     Revised by Yongjiu Dai and Hua Yuan, April 2014
   ! ======================================================================

   use MOD_Precision
   use MOD_SPMD_Task
   use MOD_Namelist
   USE MOD_Vars_Global
   USE MOD_Const_LC
   USE MOD_Const_PFT
   use MOD_Const_Physical
   use MOD_Vars_TimeInvariants
   use MOD_Vars_TimeVariables
   use MOD_Vars_1DForcing
   use MOD_Vars_2DForcing
   use MOD_Vars_1DFluxes
   use MOD_Vars_2DFluxes
   USE MOD_Vars_1DAccFluxes
   use MOD_Forcing
   use MOD_Hist
   use MOD_TimeManager
   use MOD_RangeCheck

   use MOD_Block
   use MOD_Pixel
   USE MOD_Mesh
   use MOD_LandElm
#ifdef CATCHMENT
   USE MOD_LandHRU
#endif
   use MOD_LandPatch
#ifdef URBAN_MODEL
   USE MOD_LandUrban
   USE MOD_Urban_LAIReadin
#endif
#ifdef LULC_IGBP_PFT
   USE MOD_LandPFT
#endif
#ifdef LULC_IGBP_PC
   USE MOD_LandPC
#endif
#if (defined UNSTRUCTURED || defined CATCHMENT)
   USE MOD_ElmVector
#endif
#ifdef CATCHMENT
   USE MOD_HRUVector
#endif
#if(defined CaMa_Flood)
   use MOD_CaMa_colmCaMa ! whether cama-flood is used
#endif
#ifdef SinglePoint
   USE MOD_SingleSrfdata
#endif

#if (defined LATERAL_FLOW)
   USE MOD_Hydro_LateralFlow
#endif

   USE MOD_Ozone, only: init_ozone_data, update_ozone_data

   use MOD_SrfdataRestart
   USE MOD_LAIReadin

#ifdef BGC
   USE MOD_NitrifData
   USE MOD_NdepData
   USE MOD_FireData
   USE MOD_LightningData
#endif

#ifdef LULCC
   USE MOD_Lulcc_Driver
#endif

   ! SNICAR
   USE MOD_SnowSnicar, only: SnowAge_init, SnowOptics_init
   USE MOD_Aerosol, only: AerosolDepInit, AerosolDepReadin

   IMPLICIT NONE

   character(LEN=256) :: nlfile
   character(LEN=256) :: casename
   character(len=256) :: dir_landdata
   character(len=256) :: dir_forcing
   character(len=256) :: dir_hist
   character(len=256) :: dir_restart
   character(len=256) :: fsrfdata

   real(r8) :: deltim       ! time step (senconds)
   integer  :: sdate(3)     ! calendar (year, julian day, seconds)
   integer  :: idate(3)     ! calendar (year, julian day, seconds)
   integer  :: edate(3)     ! calendar (year, julian day, seconds)
   integer  :: pdate(3)     ! calendar (year, julian day, seconds)
   integer  :: jdate(3)     ! calendar (year, julian day, seconds), year beginning style
   logical  :: greenwich    ! greenwich time

   logical :: doalb         ! true => start up the surface albedo calculation
   logical :: dolai         ! true => start up the time-varying vegetation paramter
   logical :: dosst         ! true => update sst/ice/snow

   integer :: Julian_1day_p, Julian_1day
   integer :: Julian_8day_p, Julian_8day
   integer :: s_year, s_month, s_day, s_seconds, s_julian
   integer :: e_year, e_month, e_day, e_seconds, e_julian
   integer :: p_year, p_month, p_day, p_seconds, p_julian
   integer :: lc_year, lai_year
   integer :: month, mday, year_p, month_p, mday_p
   integer :: spinup_repeat, istep

   type(timestamp) :: ststamp, itstamp, etstamp, ptstamp

   integer*8 :: start_time, end_time, c_per_sec, time_used

#ifdef USEMPI
   call spmd_init ()
#endif

   if (p_is_master) then
      call system_clock (start_time)
   end if

   call getarg (1, nlfile)

   call read_namelist (nlfile)

   casename     = DEF_CASE_NAME
   dir_landdata = DEF_dir_landdata
   dir_forcing  = DEF_dir_forcing
   dir_hist     = DEF_dir_history
   dir_restart  = DEF_dir_restart

#ifdef SinglePoint
   fsrfdata = trim(dir_landdata) // '/srfdata.nc'
   CALL read_surface_data_single (fsrfdata, mksrfdata=.false.)
#endif

   deltim    = DEF_simulation_time%timestep
   greenwich = DEF_simulation_time%greenwich
   s_year    = DEF_simulation_time%start_year
   s_month   = DEF_simulation_time%start_month
   s_day     = DEF_simulation_time%start_day
   s_seconds = DEF_simulation_time%start_sec
   e_year    = DEF_simulation_time%end_year
   e_month   = DEF_simulation_time%end_month
   e_day     = DEF_simulation_time%end_day
   e_seconds = DEF_simulation_time%end_sec
   p_year    = DEF_simulation_time%spinup_year
   p_month   = DEF_simulation_time%spinup_month
   p_day     = DEF_simulation_time%spinup_day
   p_seconds = DEF_simulation_time%spinup_sec

   spinup_repeat = DEF_simulation_time%spinup_repeat

   call initimetype(greenwich)
   call monthday2julian(s_year,s_month,s_day,s_julian)
   call monthday2julian(e_year,e_month,e_day,e_julian)
   call monthday2julian(p_year,p_month,p_day,p_julian)

   sdate(1) = s_year; sdate(2) = s_julian; sdate(3) = s_seconds
   edate(1) = e_year; edate(2) = e_julian; edate(3) = e_seconds
   pdate(1) = p_year; pdate(2) = p_julian; pdate(3) = p_seconds

   CALL Init_GlobalVars
   CAll Init_LC_Const
   CAll Init_PFT_Const

   call pixel%load_from_file    (dir_landdata)
   call gblock%load_from_file   (dir_landdata)

#ifdef LULCC
   lc_year = s_year
#else
   lc_year = DEF_LC_YEAR
#endif

   call mesh_load_from_file (dir_landdata, lc_year)

   call pixelset_load_from_file (dir_landdata, 'landelm'  , landelm  , numelm  , lc_year)

#ifdef CATCHMENT
   CALL pixelset_load_from_file (dir_landdata, 'landhru'  , landhru  , numhru  , lc_year)
#endif

   call pixelset_load_from_file (dir_landdata, 'landpatch', landpatch, numpatch, lc_year)

#ifdef LULC_IGBP_PFT
   call pixelset_load_from_file (dir_landdata, 'landpft'  , landpft  , numpft  , lc_year)
   CALL map_patch_to_pft
#endif

#ifdef LULC_IGBP_PC
   call pixelset_load_from_file (dir_landdata, 'landpc'   , landpc   , numpc   , lc_year)
   CALL map_patch_to_pc
#endif

#ifdef URBAN_MODEL
   call pixelset_load_from_file (dir_landdata, 'landurban', landurban, numurban, lc_year)
   CALL map_patch_to_urban
#endif

#if (defined UNSTRUCTURED || defined CATCHMENT)
   CALL elm_vector_init ()
#ifdef CATCHMENT
   CALL hru_vector_init ()
#endif
#endif

   call adj2end(sdate)
   call adj2end(edate)
   call adj2end(pdate)

   ststamp = sdate
   etstamp = edate
   ptstamp = pdate

   ! date in beginning style
   jdate = sdate
   CALL adj2begin(jdate)

   IF (ptstamp <= ststamp) THEN
      spinup_repeat = 0
   ELSE
      spinup_repeat = max(0, spinup_repeat)
   ENDIF

   ! ----------------------------------------------------------------------
   ! Read in the model time invariant constant data
   CALL allocate_TimeInvariants ()
   CALL READ_TimeInvariants (lc_year, casename, dir_restart)

   ! Read in the model time varying data (model state variables)
   CALL allocate_TimeVariables  ()
   CALL READ_TimeVariables (jdate, lc_year, casename, dir_restart)

   ! Read in SNICAR optical and aging parameters
   CALL SnowOptics_init( DEF_file_snowoptics ) ! SNICAR optical parameters
   CALL SnowAge_init( DEF_file_snowaging )     ! SNICAR aging   parameters

   !-----------------------
   doalb = .true.
   dolai = .true.
   dosst = .false.

   ! Initialize meteorological forcing data module
   call allocate_1D_Forcing ()
   CALL forcing_init (dir_forcing, deltim, sdate, lc_year)
   call allocate_2D_Forcing (gforc)

   ! Initialize history data module
   call hist_init (dir_hist, DEF_hist_lon_res, DEF_hist_lat_res)
   call allocate_2D_Fluxes (ghist)
   call allocate_1D_Fluxes ()


#if(defined CaMa_Flood)
   call colm_CaMa_init !initialize CaMa-Flood
#endif

   IF(DEF_USE_OZONEDATA)THEN
      CALL init_Ozone_data (sdate)
   ENDIF

   ! Initialize aerosol deposition forcing data
   IF (DEF_Aerosol_Readin) THEN
      CALL AerosolDepInit ()
   ENDIF

#ifdef BGC
   IF (DEF_USE_NITRIF) then
      CALL init_nitrif_data (sdate)
   ENDIF

   CALL init_ndep_data (sdate(1))

   IF (DEF_USE_FIRE) THEN
      CALL init_fire_data (sdate(1))
      CALL init_lightning_data (sdate)
   ENDIF
#endif

#if (defined LATERAL_FLOW)
   CALL lateral_flow_init ()
#endif

   ! ======================================================================
   ! begin time stepping loop
   ! ======================================================================

   istep   = 1
   idate   = sdate
   itstamp = ststamp

   TIMELOOP : DO while (itstamp < etstamp)

      CALL julian2monthday (jdate(1), jdate(2), month_p, mday_p)

      year_p = jdate(1)

      if (p_is_master) then
         IF (itstamp < ptstamp) THEN
            write(*, 99) istep, jdate(1), month_p, mday_p, jdate(3), spinup_repeat
         ELSE
            write(*,100) istep, jdate(1), month_p, mday_p, jdate(3)
         ENDIF
      end if


      Julian_1day_p = int(calendarday(jdate)-1)/1*1 + 1
      Julian_8day_p = int(calendarday(jdate)-1)/8*8 + 1

      ! Read in the meteorological forcing
      ! ----------------------------------------------------------------------
      CALL read_forcing (idate, dir_forcing)

      IF(DEF_USE_OZONEDATA)THEN
         CALL update_Ozone_data(itstamp, deltim)
      ENDIF
#ifdef BGC
      IF(DEF_USE_FIRE)THEN
         CALL update_lightning_data (itstamp, deltim)
      ENDIF
#endif

      ! Read in aerosol deposition forcing data
      IF (DEF_Aerosol_Readin) THEN
         CALL AerosolDepReadin (jdate)
      ENDIF

      ! Calendar for NEXT time step
      ! ----------------------------------------------------------------------
      CALL TICKTIME (deltim,idate)
      itstamp = itstamp + int(deltim)
      jdate = idate
      CALL adj2begin(jdate)

      CALL julian2monthday (jdate(1), jdate(2), month, mday)

#ifdef BGC
      if(DEF_USE_NITRIF) then
         IF (month /= month_p) THEN
            CALL update_nitrif_data (month)
         end if
      end if
      
      IF (jdate(1) /= year_p) THEN
         CALL update_ndep_data (idate(1), iswrite = .true.)
      ENDIF

      if(DEF_USE_FIRE)then
         IF (jdate(1) /= year_p) THEN
            CALL update_hdm_data (idate(1))
         end if
      end if
#endif

      ! lateral flow
#if (defined LATERAL_FLOW)
      CALL lateral_flow (deltim)
#endif

      ! Call colm driver
      ! ----------------------------------------------------------------------
      IF (p_is_worker) THEN
         CALL CoLMDRIVER (idate,deltim,dolai,doalb,dosst,oroflag)
      ENDIF

      ! Get leaf area index
      ! ----------------------------------------------------------------------
#if(defined DYN_PHENOLOGY)
      ! Update once a day
      dolai = .false.
      Julian_1day = int(calendarday(jdate)-1)/1*1 + 1
      if(Julian_1day /= Julian_1day_p)then
         dolai = .true.
      endif
#else
      ! READ in Leaf area index and stem area index
      ! ----------------------------------------------------------------------
      ! Hua Yuan, 08/03/2019: read global monthly LAI/SAI data
      ! zhongwang wei, 20210927: add option to read non-climatological mean LAI
      ! Update every 8 days (time interval of the MODIS LAI data)
      ! Hua Yuan, 06/2023: change namelist DEF_LAI_CLIM to DEF_LAI_MONTHLY
      ! and add DEF_LAI_CHANGE_YEARLY for monthly LAI data
      !
      ! NOTES: Should be caution for setting DEF_LAI_CHANGE_YEARLY to ture in non-LULCC
      ! case, that means the LAI changes without condisderation of land cover change.

      IF (DEF_LAI_CHANGE_YEARLY) THEN
         lai_year = jdate(1)
      ELSE
         lai_year = DEF_LC_YEAR
      ENDIF

      IF (DEF_LAI_MONTHLY) THEN
         IF (month /= month_p) THEN
               CALL LAI_readin (lai_year, month, dir_landdata)
#ifdef URBAN_MODEL
               CALL UrbanLAI_readin(lai_year, month, dir_landdata)
#endif
         ENDIF
      ELSE
         ! Update every 8 days (time interval of the MODIS LAI data)
         Julian_8day = int(calendarday(jdate)-1)/8*8 + 1
         if(Julian_8day /= Julian_8day_p)then
            CALL LAI_readin (jdate(1), Julian_8day, dir_landdata)
            ! 06/2023, yuan: or depend on DEF_LAI_CHANGE_YEARLY nanemlist
            !CALL LAI_readin (lai_year, Julian_8day, dir_landdata)
         ENDIF
      ENDIF
#endif

#if(defined CaMa_Flood)
   call colm_CaMa_drv(idate(3)) ! run CaMa-Flood
#endif

      ! Write out the model variables for restart run and the histroy file
      ! ----------------------------------------------------------------------
      call hist_out (idate, deltim, itstamp, ptstamp, dir_hist, casename)

#ifdef LULCC
      ! DO land use and land cover change simulation
      IF ( isendofyear(idate, deltim) ) THEN
         CALL deallocate_1D_Forcing
         CALL deallocate_1D_Fluxes

         CALL LulccDriver (casename,dir_landdata,dir_restart,&
                           idate,greenwich)

         CALL allocate_1D_Forcing
         CALL forcing_init (dir_forcing, deltim, idate, jdate(1))
         CALL deallocate_acc_fluxes
         call hist_init (dir_hist, DEF_hist_lon_res, DEF_hist_lat_res)
         CALL allocate_1D_Fluxes
      ENDIF
#endif

      if (save_to_restart (idate, deltim, itstamp, ptstamp)) then
#ifdef LULCC
         call WRITE_TimeVariables (jdate, jdate(1), casename, dir_restart)
#else
         call WRITE_TimeVariables (jdate, lc_year,  casename, dir_restart)
#endif
      endif

#ifdef RangeCheck
      call check_TimeVariables ()
#endif

#ifdef USEMPI
      call mpi_barrier (p_comm_glb, p_err)
#endif

      if (p_is_master) then
         call system_clock (end_time, count_rate = c_per_sec)
         time_used = (end_time - start_time) / c_per_sec
         if (time_used >= 3600) then
            write(*,101) time_used/3600, mod(time_used,3600)/60, mod(time_used,60)
         elseif (time_used >= 60) then
            write(*,102) time_used/60, mod(time_used,60)
         else
            write(*,103) time_used
         end if
      end if

      IF ((spinup_repeat > 1) .and. (ptstamp <= itstamp)) THEN
         spinup_repeat = spinup_repeat - 1
         idate   = sdate
         itstamp = ststamp
         CALL forcing_reset ()
      ENDIF

      istep = istep + 1

   END DO TIMELOOP

   call deallocate_TimeInvariants ()
   call deallocate_TimeVariables  ()
   call deallocate_1D_Forcing     ()
   call deallocate_1D_Fluxes      ()

#if (defined LATERAL_FLOW)
   CALL lateral_flow_final ()
#endif

   call hist_final ()

#ifdef SinglePoint
   CALL single_srfdata_final ()
#endif

#ifdef USEMPI
   call mpi_barrier (p_comm_glb, p_err)
#endif

#if(defined CaMa_Flood)
   call colm_cama_exit ! finalize CaMa-Flood
#endif

   if (p_is_master) then
      write(*,'(/,A25)') 'CoLM Execution Completed.'
   end if

   99  format(/, 'TIMESTEP = ', I0, ' | DATE = ', I4.4, '-', I2.2, '-', I2.2, '-', I5.5, ' Spinup (', I0, ' repeat left)')
   100 format(/, 'TIMESTEP = ', I0, ' | DATE = ', I4.4, '-', I2.2, '-', I2.2, '-', I5.5)
   101 format (/, 'Time elapsed : ', I4, ' hours', I3, ' minutes', I3, ' seconds.')
   102 format (/, 'Time elapsed : ', I3, ' minutes', I3, ' seconds.')
   103 format (/, 'Time elapsed : ', I3, ' seconds.')

#ifdef USEMPI
   CALL spmd_exit
#endif

END PROGRAM CoLM
! ----------------------------------------------------------------------
! EOP
