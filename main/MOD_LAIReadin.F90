#include <define.h>

MODULE MOD_LAIReadin

!-----------------------------------------------------------------------
   USE MOD_Precision
   IMPLICIT NONE
   SAVE

! PUBLIC MEMBER FUNCTIONS:
   PUBLIC :: LAI_readin


!-----------------------------------------------------------------------

   CONTAINS

!-----------------------------------------------------------------------


   SUBROUTINE LAI_readin (year, time, dir_landdata)
      ! ===========================================================
      ! Read in the LAI, the LAI dataset was created by Yuan et al. (2011)
      ! http://globalchange.bnu.edu.cn
      !
      ! Created by Yongjiu Dai, March, 2014
      ! ===========================================================

      use MOD_Precision
      use MOD_Namelist
      use MOD_SPMD_Task
      use MOD_NetCDFVector
      use MOD_LandPatch
      use MOD_Vars_TimeInvariants
      use MOD_Vars_TimeVariables

      USE MOD_Vars_Global
      USE MOD_Const_LC
#ifdef LULC_IGBP_PFT
      USE MOD_LandPFT
      USE MOD_Vars_PFTimeVariables
#endif
#ifdef LULC_IGBP_PC
      USE MOD_LandPC
      USE MOD_Vars_PCTimeVariables
      USE MOD_Vars_PCTimeInvariants
#endif
#ifdef SinglePoint
      USE MOD_SingleSrfdata
#endif

      IMPLICIT NONE

      integer, INTENT(in) :: year, time
      character(LEN=256), INTENT(in) :: dir_landdata

      ! Local variables
      integer :: iyear, itime
      character(LEN=256) :: cyear, ctime
      character(LEN=256) :: landdir, lndname
      integer :: m, npatch, pc

#ifdef LULC_USGS
      real(r8), dimension(24), parameter :: &   ! Maximum fractional cover of vegetation [-]
         vegc=(/1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, &
                1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 0.0, &
                1.0, 1.0, 0.0, 1.0, 1.0, 1.0, 0.0, 0.0 /)
#endif

      ! READ in Leaf area index and stem area index

      landdir = trim(dir_landdata) // '/LAI'

#ifdef SinglePoint
      iyear = findloc(SITE_LAI_year, year, dim=1)
      IF (.not. DEF_LAI_MONTHLY) THEN
         itime = (time-1)/8 + 1
      ENDIF
#endif

#if (defined LULC_USGS || defined LULC_IGBP)

!TODO: need to consider single point for urban model
#ifdef SinglePoint
      IF (DEF_LAI_MONTHLY) THEN
         tlai(:) = SITE_LAI_monthly(time,iyear)
         tsai(:) = SITE_SAI_monthly(time,iyear)
      ELSE
         tlai(:) = SITE_LAI_8day(itime,iyear)
      ENDIF
#else
      IF (DEF_LAI_MONTHLY) THEN
         write(cyear,'(i4.4)') year
         write(ctime,'(i2.2)') time

         lndname = trim(landdir)//'/'//trim(cyear)//'/LAI_patches'//trim(ctime)//'.nc'
         call ncio_read_vector (lndname, 'LAI_patches',  landpatch, tlai)

         lndname = trim(landdir)//'/'//trim(cyear)//'/SAI_patches'//trim(ctime)//'.nc'
         call ncio_read_vector (lndname, 'SAI_patches',  landpatch, tsai)
      ELSE
         write(cyear,'(i4.4)') year
         write(ctime,'(i3.3)') time
         lndname = trim(landdir)//'/'//trim(cyear)//'/LAI_patches'//trim(ctime)//'.nc'
         call ncio_read_vector (lndname, 'LAI_patches',  landpatch, tlai)
      ENDIF
#endif

      if (p_is_worker) then
         if (numpatch > 0) then

            do npatch = 1, numpatch
               m = patchclass(npatch)
#ifdef URBAN_MODEL
               IF(m == URBAN) CYCLE
#endif
               if( m == 0 )then
                  fveg(npatch)  = 0.
                  tlai(npatch)  = 0.
                  tsai(npatch)  = 0.
                  green(npatch) = 0.
               else
                  fveg(npatch)  = fveg0(m)           !fraction of veg. cover
                  IF (fveg0(m) > 0) THEN
                     tlai(npatch)  = tlai(npatch)/fveg0(m) !leaf area index
                     IF (DEF_LAI_MONTHLY) THEN
                        tsai(npatch)  = tsai(npatch)/fveg0(m) !stem are index
                     ELSE
                        tsai(npatch)  = sai0(m) !stem are index
                     ENDIF
                     green(npatch) = 1.      !fraction of green leaf
                  ELSE
                     tlai(npatch)  = 0.
                     tsai(npatch)  = 0.
                     green(npatch) = 0.
                  ENDIF
               endif
            end do

         ENDIF
      ENDIF

#endif

#ifdef LULC_IGBP_PFT

#ifdef SinglePoint
      !TODO: how to add time parameter in single point case
      IF (DEF_LAI_MONTHLY) THEN
         tlai_p(:) = pack(SITE_LAI_pfts_monthly(:,time,iyear), SITE_pctpfts > 0.)
         tsai_p(:) = pack(SITE_SAI_pfts_monthly(:,time,iyear), SITE_pctpfts > 0.)
         tlai(:)   = sum (SITE_LAI_pfts_monthly(:,time,iyear) * SITE_pctpfts)
         tsai(:)   = sum (SITE_SAI_pfts_monthly(:,time,iyear) * SITE_pctpfts)
      ENDIF
#else

      write(cyear,'(i4.4)') year
      write(ctime,'(i2.2)') time
      IF (.not. DEF_USE_LAIFEEDBACK)THEN
         lndname = trim(landdir)//'/'//trim(cyear)//'/LAI_patches'//trim(ctime)//'.nc'
         call ncio_read_vector (lndname, 'LAI_patches',  landpatch, tlai )
      END IF
      lndname = trim(landdir)//'/'//trim(cyear)//'/SAI_patches'//trim(ctime)//'.nc'
      call ncio_read_vector (lndname, 'SAI_patches',  landpatch, tsai )
      IF (.not. DEF_USE_LAIFEEDBACK)THEN
         lndname = trim(landdir)//'/'//trim(cyear)//'/LAI_pfts'//trim(ctime)//'.nc'
         call ncio_read_vector (lndname, 'LAI_pfts', landpft, tlai_p )
      END IF
      lndname = trim(landdir)//'/'//trim(cyear)//'/SAI_pfts'//trim(ctime)//'.nc'
      call ncio_read_vector (lndname, 'SAI_pfts', landpft, tsai_p )

#endif

      if (p_is_worker) then
         if (numpatch > 0) then
            do npatch = 1, numpatch
               m = patchclass(npatch)

#ifdef URBAN_MODEL
               IF (m == URBAN) CYCLE
#endif
               green(npatch) = 1.
               fveg (npatch)  = fveg0(m)

            end do
         ENDIF
      ENDIF

#endif

#ifdef LULC_IGBP_PC

#ifdef SinglePoint
      IF (DEF_LAI_MONTHLY) THEN
         tlai(:)   = sum(SITE_LAI_pfts_monthly(:,time,iyear) * SITE_pctpfts)
         tsai(:)   = sum(SITE_SAI_pfts_monthly(:,time,iyear) * SITE_pctpfts)
         tlai_c(:,1) = SITE_LAI_pfts_monthly(:,time,iyear)
         tsai_c(:,1) = SITE_SAI_pfts_monthly(:,time,iyear)
      ENDIF
#else

      write(cyear,'(i4.4)') year
      write(ctime,'(i2.2)') time
      lndname = trim(landdir)//'/'//trim(cyear)//'/LAI_patches'//trim(ctime)//'.nc'
      call ncio_read_vector (lndname, 'LAI_patches',  landpatch, tlai )

      lndname = trim(landdir)//'/'//trim(cyear)//'/SAI_patches'//trim(ctime)//'.nc'
      call ncio_read_vector (lndname, 'SAI_patches',  landpatch, tsai )

      lndname = trim(landdir)//'/'//trim(cyear)//'/LAI_pcs'//trim(ctime)//'.nc'
      call ncio_read_vector (lndname, 'LAI_pcs', N_PFT, landpc, tlai_c )

      lndname = trim(landdir)//'/'//trim(cyear)//'/SAI_pcs'//trim(ctime)//'.nc'
      call ncio_read_vector (lndname, 'SAI_pcs', N_PFT, landpc, tsai_c )

#endif

      if (p_is_worker) then
         if (numpatch > 0) then
            do npatch = 1, numpatch
               m = patchclass(npatch)

#ifdef URBAN_MODEL
               IF (m == URBAN) CYCLE
#endif
               IF (patchtypes(landpatch%settyp(npatch)) == 0) THEN
                  pc = patch2pc(npatch)

                  tlai(npatch) = sum(tlai_c(:,pc)*pcfrac(:,pc))
                  tsai(npatch) = sum(tsai_c(:,pc)*pcfrac(:,pc))
               ENDIF

               fveg (npatch)  = fveg0(m)
               green(npatch) = 1.
            end do
         ENDIF
      ENDIF

#endif

   END SUBROUTINE LAI_readin

END MODULE MOD_LAIReadin
